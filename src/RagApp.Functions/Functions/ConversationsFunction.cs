using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;
using RagApp.Functions.Services;

namespace RagApp.Functions.Functions;

/// <summary>
/// Chat history endpoints. History itself lives in Microsoft Foundry conversations
/// (backed by the customer-managed Cosmos DB); the PostgreSQL conversations table maps
/// users to their conversation ids and enforces ownership via row-level security.
/// </summary>
public class ConversationsFunction
{
    private readonly ITokenValidator _tokenValidator;
    private readonly FoundryConversationService _conversations;
    private readonly PgVectorStore _store;

    public ConversationsFunction(
        ITokenValidator tokenValidator,
        FoundryConversationService conversations,
        PgVectorStore store)
    {
        _tokenValidator = tokenValidator;
        _conversations = conversations;
        _store = store;
    }

    [Function("ListConversations")]
    public async Task<IActionResult> List(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "conversations")] HttpRequest request,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        return new OkObjectResult(await _store.ListConversationsAsync(user, ct));
    }

    [Function("CreateConversation")]
    public async Task<IActionResult> Create(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "conversations")] HttpRequest request,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        string? title = null;
        if (request.ContentLength is > 0)
        {
            var body = await request.ReadFromJsonAsync<CreateConversationRequest>(ct);
            title = body?.Title;
        }

        title = string.IsNullOrWhiteSpace(title) ? "New conversation" : title;
        var conversationId = await _conversations.CreateConversationAsync(user.ObjectId, title, ct);
        await _store.AddConversationAsync(user, conversationId, title, ct);

        var now = DateTimeOffset.UtcNow;
        return new OkObjectResult(new ConversationSummary(conversationId, title, now, now));
    }

    [Function("GetConversation")]
    public async Task<IActionResult> Get(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "conversations/{id}")] HttpRequest request,
        string id,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        if (!await _store.OwnsConversationAsync(user, id, ct))
        {
            return new NotFoundObjectResult(new { error = "Conversation not found." });
        }

        var messages = await _conversations.GetMessagesAsync(id, ct);
        return new OkObjectResult(new { id, messages });
    }

    [Function("DeleteConversation")]
    public async Task<IActionResult> Delete(
        [HttpTrigger(AuthorizationLevel.Anonymous, "delete", Route = "conversations/{id}")] HttpRequest request,
        string id,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        if (!await _store.OwnsConversationAsync(user, id, ct))
        {
            return new NotFoundObjectResult(new { error = "Conversation not found." });
        }

        await _store.DeleteConversationAsync(user, id, ct);
        await _conversations.DeleteConversationAsync(id, ct);
        return new NoContentResult();
    }
}
