using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Coordinates a chat turn: resolves (or creates) the caller's conversation, replays
/// persisted history from Foundry, runs the RAG agent, and appends the new turn.
/// </summary>
public class ChatOrchestrator
{
    private readonly RagAgentService _agentService;
    private readonly FoundryConversationService _conversations;
    private readonly PgVectorStore _store;

    public ChatOrchestrator(
        RagAgentService agentService,
        FoundryConversationService conversations,
        PgVectorStore store)
    {
        _agentService = agentService;
        _conversations = conversations;
        _store = store;
    }

    public async Task<ChatResponse> HandleAsync(
        UserContext user, string message, int topK, string? conversationId, CancellationToken ct = default)
    {
        IReadOnlyList<ConversationMessage> history = [];

        if (!string.IsNullOrWhiteSpace(conversationId))
        {
            // Ownership check: RLS on the conversations table is the authorization boundary.
            if (!await _store.OwnsConversationAsync(user, conversationId, ct))
            {
                throw new UnauthorizedAccessException("Conversation not found for this user.");
            }

            history = await _conversations.GetMessagesAsync(conversationId, ct);
        }
        else
        {
            var title = message.Length > 60 ? message[..60] + "…" : message;
            conversationId = await _conversations.CreateConversationAsync(user.ObjectId, title, ct);
            await _store.AddConversationAsync(user, conversationId, title, ct);
        }

        var response = await _agentService.AskAsync(user, message, topK, history, conversationId, ct);

        await _conversations.AddMessagesAsync(conversationId,
        [
            new ConversationMessage("user", message, DateTimeOffset.UtcNow),
            new ConversationMessage("assistant", response.Answer, DateTimeOffset.UtcNow)
        ], ct);
        await _store.TouchConversationAsync(user, conversationId, null, ct);

        return response;
    }
}
