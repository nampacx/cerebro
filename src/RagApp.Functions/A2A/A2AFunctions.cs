using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;
using RagApp.Functions.Services;

namespace RagApp.Functions.A2A;

/// <summary>
/// A2A protocol endpoints: the public agent card for discovery and the JSON-RPC
/// message endpoint. Partner agents authenticate with an Entra ID token obtained
/// via the OAuth2 on-behalf-of flow, so retrieval runs under the END USER's
/// identity and row-level security — never the calling agent's app identity.
/// </summary>
public class A2AFunctions
{
    private readonly ITokenValidator _tokenValidator;
    private readonly ChatOrchestrator _orchestrator;
    private readonly AuthOptions _authOptions;

    public A2AFunctions(
        ITokenValidator tokenValidator,
        ChatOrchestrator orchestrator,
        IOptions<AuthOptions> authOptions)
    {
        _tokenValidator = tokenValidator;
        _orchestrator = orchestrator;
        _authOptions = authOptions.Value;
    }

    [Function("AgentCard")]
    public IActionResult GetAgentCard(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = ".well-known/agent-card.json")] HttpRequest request)
    {
        var baseUrl = $"{request.Scheme}://{request.Host}";
        var card = new
        {
            protocolVersion = "0.3.0",
            name = "Enterprise RAG Agent",
            description =
                "Retrieval-augmented document assistant. Answers questions over documents stored in a " +
                "pgvector knowledge base with per-user row-level security. Callers must present an Entra ID " +
                "token for the end user (acquired directly or via the OAuth2 on-behalf-of flow), so answers " +
                "only draw on documents that user is allowed to see.",
            url = $"{baseUrl}/api/a2a",
            preferredTransport = "JSONRPC",
            version = "1.0.0",
            capabilities = new
            {
                streaming = false,
                pushNotifications = false,
                stateTransitionHistory = false
            },
            defaultInputModes = new[] { "text/plain" },
            defaultOutputModes = new[] { "text/plain" },
            securitySchemes = new Dictionary<string, object>
            {
                ["entra-obo"] = new
                {
                    type = "oauth2",
                    description =
                        "Entra ID. Partner agents holding a user token for their own API must exchange it " +
                        $"via the on-behalf-of grant for a token with scope api://{_authOptions.ClientId}/access_as_user, " +
                        "then send it as a Bearer token. Row-level security is enforced as the end user.",
                    flows = new
                    {
                        authorizationCode = new
                        {
                            authorizationUrl = $"https://login.microsoftonline.com/{_authOptions.TenantId}/oauth2/v2.0/authorize",
                            tokenUrl = $"https://login.microsoftonline.com/{_authOptions.TenantId}/oauth2/v2.0/token",
                            scopes = new Dictionary<string, string>
                            {
                                [$"api://{_authOptions.ClientId}/access_as_user"] =
                                    "Query documents on behalf of the signed-in user"
                            }
                        }
                    }
                }
            },
            security = new[]
            {
                new Dictionary<string, string[]>
                {
                    ["entra-obo"] = [$"api://{_authOptions.ClientId}/access_as_user"]
                }
            },
            skills = new[]
            {
                new
                {
                    id = "document-qa",
                    name = "Document question answering",
                    description =
                        "Answers natural-language questions grounded in the user's accessible documents, " +
                        "with citations (filename, page).",
                    tags = new[] { "rag", "documents", "search", "citations" },
                    examples = new[]
                    {
                        "What does the Q3 report say about revenue growth?",
                        "Summarize the onboarding guide."
                    }
                }
            }
        };

        return new OkObjectResult(card);
    }

    [Function("A2AMessages")]
    public async Task<IActionResult> HandleMessage(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "a2a")] HttpRequest request,
        CancellationToken ct)
    {
        JsonRpcRequest? rpc;
        try
        {
            rpc = await JsonSerializer.DeserializeAsync<JsonRpcRequest>(request.Body, cancellationToken: ct);
        }
        catch (JsonException)
        {
            return RpcError(null, -32700, "Parse error");
        }

        if (rpc is null || rpc.JsonRpc != "2.0")
        {
            return RpcError(null, -32600, "Invalid request");
        }

        // The bearer token carries the end user identity (direct or via OBO exchange).
        var user = await _tokenValidator.ValidateAsync(request, ct);
        if (user is null)
        {
            return RpcError(rpc.Id, -32001,
                "Unauthorized: present an Entra ID user token (use the on-behalf-of flow for agent-to-agent calls).");
        }

        if (rpc.Method != "message/send")
        {
            return RpcError(rpc.Id, -32601, $"Method '{rpc.Method}' not supported. Use 'message/send'.");
        }

        var sendParams = rpc.Params.ValueKind == JsonValueKind.Object
            ? rpc.Params.Deserialize<A2AMessageSendParams>()
            : null;
        var text = sendParams?.Message.Parts.FirstOrDefault(p => p.Kind == "text")?.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            return RpcError(rpc.Id, -32602, "Invalid params: message must contain a text part.");
        }

        // Partner agents get a persisted conversation too, keyed by contextId when supplied.
        ChatResponse answer;
        try
        {
            answer = await _orchestrator.HandleAsync(
                user, text, 5, sendParams!.Message.ContextId, ct);
        }
        catch (UnauthorizedAccessException)
        {
            return RpcError(rpc.Id, -32001, "The supplied contextId does not belong to the authenticated user.");
        }

        var responseMessage = new A2AMessage
        {
            Role = "agent",
            ContextId = answer.ConversationId,
            Parts = [new A2APart { Kind = "text", Text = answer.Answer }]
        };

        return new OkObjectResult(new JsonRpcResponse { Id = rpc.Id, Result = responseMessage });
    }

    private static IActionResult RpcError(JsonElement? id, int code, string message) =>
        new OkObjectResult(new JsonRpcResponse
        {
            Id = id,
            Error = new JsonRpcError { Code = code, Message = message }
        });
}
