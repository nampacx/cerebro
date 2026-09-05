using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Wraps the Microsoft Foundry conversations API, which persists chat history
/// server-side in the project's customer-managed Cosmos DB (BYO thread storage).
/// Ownership of a conversation is enforced separately by
/// <see cref="ConversationIndex"/>, which maps users to conversation ids.
/// </summary>
public class FoundryConversationService
{
    private static readonly string[] Scope = ["https://cognitiveservices.azure.com/.default"];

    private readonly HttpClient _httpClient;
    private readonly TokenCredential _credential;
    private readonly ILogger<FoundryConversationService> _logger;
    private readonly Uri _baseUri;

    public FoundryConversationService(
        HttpClient httpClient,
        TokenCredential credential,
        IOptions<RagOptions> options,
        ILogger<FoundryConversationService> logger)
    {
        _httpClient = httpClient;
        _credential = credential;
        _logger = logger;
        _baseUri = new Uri(options.Value.OpenAiEndpoint.TrimEnd('/') + "/openai/v1/");
    }

    private async Task AuthorizeAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(Scope), ct);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
    }

    private async Task<JsonElement> SendAsync(
        HttpMethod method, string relativePath, object? body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, new Uri(_baseUri, relativePath));
        await AuthorizeAsync(request, ct);
        if (body is not null)
        {
            request.Content = JsonContent.Create(body);
        }

        using var response = await _httpClient.SendAsync(request, ct);
        var payload = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError(
                "Foundry conversations API {Method} {Path} failed: {Status} {Payload}",
                method, relativePath, response.StatusCode, payload);
            throw new HttpRequestException(
                $"Foundry conversations API returned {(int)response.StatusCode}.");
        }

        return string.IsNullOrWhiteSpace(payload)
            ? default
            : JsonDocument.Parse(payload).RootElement.Clone();
    }

    public async Task<string> CreateConversationAsync(string userOid, string title, CancellationToken ct = default)
    {
        var result = await SendAsync(HttpMethod.Post, "conversations", new
        {
            metadata = new Dictionary<string, string>
            {
                ["userOid"] = userOid,
                ["title"] = title
            }
        }, ct);

        return result.GetProperty("id").GetString()
               ?? throw new InvalidOperationException("Foundry did not return a conversation id.");
    }

    public async Task AddMessagesAsync(
        string conversationId, IReadOnlyList<ConversationMessage> messages, CancellationToken ct = default)
    {
        if (messages.Count == 0)
        {
            return;
        }

        await SendAsync(HttpMethod.Post, $"conversations/{conversationId}/items", new
        {
            items = messages.Select(m => new
            {
                type = "message",
                role = m.Role,
                content = m.Text
            }).ToArray()
        }, ct);
    }

    public async Task<IReadOnlyList<ConversationMessage>> GetMessagesAsync(
        string conversationId, CancellationToken ct = default)
    {
        var result = await SendAsync(
            HttpMethod.Get, $"conversations/{conversationId}/items?order=asc&limit=100", null, ct);

        var messages = new List<ConversationMessage>();
        if (!result.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
        {
            return messages;
        }

        foreach (var item in data.EnumerateArray())
        {
            if (!item.TryGetProperty("type", out var type) || type.GetString() != "message")
            {
                continue;
            }

            var role = item.TryGetProperty("role", out var r) ? r.GetString() ?? "assistant" : "assistant";
            var text = ExtractText(item);
            if (!string.IsNullOrWhiteSpace(text))
            {
                messages.Add(new ConversationMessage(role, text, null));
            }
        }

        return messages;
    }

    public async Task DeleteConversationAsync(string conversationId, CancellationToken ct = default)
    {
        try
        {
            await SendAsync(HttpMethod.Delete, $"conversations/{conversationId}", null, ct);
        }
        catch (HttpRequestException ex)
        {
            // The index entry is authoritative for the user experience; log and continue.
            _logger.LogWarning(ex, "Could not delete Foundry conversation {ConversationId}", conversationId);
        }
    }

    /// <summary>Content may be a plain string or an array of typed content parts.</summary>
    private static string ExtractText(JsonElement item)
    {
        if (!item.TryGetProperty("content", out var content))
        {
            return string.Empty;
        }

        if (content.ValueKind == JsonValueKind.String)
        {
            return content.GetString() ?? string.Empty;
        }

        if (content.ValueKind == JsonValueKind.Array)
        {
            var parts = content.EnumerateArray()
                .Select(part => part.TryGetProperty("text", out var t) ? t.GetString() : null)
                .Where(t => !string.IsNullOrEmpty(t));
            return string.Join("\n", parts);
        }

        return string.Empty;
    }
}
