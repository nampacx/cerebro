using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;
using RagApp.Functions.Services;

namespace RagApp.Functions.Functions;

public class ChatFunction
{
    private readonly ITokenValidator _tokenValidator;
    private readonly ChatOrchestrator _orchestrator;

    public ChatFunction(ITokenValidator tokenValidator, ChatOrchestrator orchestrator)
    {
        _tokenValidator = tokenValidator;
        _orchestrator = orchestrator;
    }

    [Function("Chat")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "chat")] HttpRequest request,
        CancellationToken ct)
    {
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return new UnauthorizedResult();
        }

        var chatRequest = await request.ReadFromJsonAsync<ChatRequest>(ct);
        if (chatRequest is null || string.IsNullOrWhiteSpace(chatRequest.Message))
        {
            return new BadRequestObjectResult(new { error = "Request body must contain a 'message'." });
        }

        try
        {
            var response = await _orchestrator.HandleAsync(
                user, chatRequest.Message, Math.Clamp(chatRequest.TopK, 1, 20), chatRequest.ConversationId, ct);
            return new OkObjectResult(response);
        }
        catch (UnauthorizedAccessException)
        {
            return new NotFoundObjectResult(new { error = "Conversation not found." });
        }
    }
}
