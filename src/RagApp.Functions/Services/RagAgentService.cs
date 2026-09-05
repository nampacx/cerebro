using System.ComponentModel;
using System.Text.Json;
using Azure.AI.OpenAI;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;
using ChatResponse = RagApp.Functions.Models.ChatResponse;

namespace RagApp.Functions.Services;

/// <summary>
/// Builds a per-request Agent Framework agent whose retrieval tool searches the
/// pgvector store under the calling user's row-level security context.
/// </summary>
public class RagAgentService
{
    private const string Instructions =
        """
        You are an enterprise document assistant. Answer questions strictly based on the
        provided document search results. Always call the search_documents tool to look up
        relevant content before answering. Cite your sources inline using the format
        [filename, page X]. If the search returns no relevant results, say that you could
        not find the information in the documents the user has access to.
        """;

    private readonly AzureOpenAIClient _openAiClient;
    private readonly EmbeddingService _embeddingService;
    private readonly PgVectorStore _store;
    private readonly RagOptions _options;

    public RagAgentService(
        AzureOpenAIClient openAiClient,
        EmbeddingService embeddingService,
        PgVectorStore store,
        IOptions<RagOptions> options)
    {
        _openAiClient = openAiClient;
        _embeddingService = embeddingService;
        _store = store;
        _options = options.Value;
    }

    public async Task<ChatResponse> AskAsync(
        UserContext user,
        string message,
        int topK = 5,
        IReadOnlyList<ConversationMessage>? history = null,
        string conversationId = "",
        CancellationToken ct = default)
    {
        var citations = new List<CitationResult>();

        [Description("Searches the user's accessible documents for content relevant to the query. Returns text snippets with citations.")]
        async Task<string> SearchDocuments(
            [Description("The search query.")] string query)
        {
            var embedding = await _embeddingService.EmbedAsync(query, ct);
            var results = await _store.SearchAsync(user, embedding, topK, ct);
            if (results.Count == 0)
            {
                return "No matching documents found.";
            }

            var items = results.Select(r =>
            {
                var citation = JsonSerializer.Deserialize<JsonElement>(r.CitationJson);
                var filename = citation.TryGetProperty("filename", out var f) ? f.GetString() ?? "unknown" : "unknown";
                int? page = citation.TryGetProperty("page", out var p) && p.ValueKind == JsonValueKind.Number
                    ? p.GetInt32() : null;
                var chunkIndex = citation.TryGetProperty("chunkIndex", out var c) ? c.GetInt32() : 0;

                citations.Add(new CitationResult(
                    r.DocumentId.ToString(), filename, page, chunkIndex,
                    r.Content.Length > 200 ? r.Content[..200] + "…" : r.Content));

                var pageInfo = page.HasValue ? $", page {page}" : string.Empty;
                return $"[{filename}{pageInfo}] (similarity {r.Similarity:F2})\n{r.Content}";
            });

            return string.Join("\n---\n", items);
        }

        AIAgent agent = _openAiClient
            .GetChatClient(_options.ChatDeployment)
            .AsIChatClient()
            .AsAIAgent(
                instructions: Instructions,
                tools: [AIFunctionFactory.Create(SearchDocuments, name: "search_documents")]);

        // Replay persisted history (from Foundry conversations) so the model has the
        // full context of the resumed session, then append the new user turn.
        var messages = new List<ChatMessage>();
        if (history is { Count: > 0 })
        {
            messages.AddRange(history.Select(m => new ChatMessage(
                m.Role.Equals("assistant", StringComparison.OrdinalIgnoreCase)
                    ? ChatRole.Assistant
                    : ChatRole.User,
                m.Text)));
        }

        messages.Add(new ChatMessage(ChatRole.User, message));

        var response = await agent.RunAsync(messages, cancellationToken: ct);

        var distinctCitations = citations
            .GroupBy(c => (c.DocumentId, c.Page, c.ChunkIndex))
            .Select(g => g.First())
            .ToList();

        return new ChatResponse(response.Text, distinctCitations, conversationId);
    }
}
