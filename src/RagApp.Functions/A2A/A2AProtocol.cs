using System.Text.Json;
using System.Text.Json.Serialization;

namespace RagApp.Functions.A2A;

// Minimal A2A protocol DTOs (JSON-RPC 2.0 transport, message/send method).

public class JsonRpcRequest
{
    [JsonPropertyName("jsonrpc")] public string JsonRpc { get; set; } = "2.0";
    [JsonPropertyName("id")] public JsonElement Id { get; set; }
    [JsonPropertyName("method")] public string Method { get; set; } = string.Empty;
    [JsonPropertyName("params")] public JsonElement Params { get; set; }
}

public class JsonRpcResponse
{
    [JsonPropertyName("jsonrpc")] public string JsonRpc { get; set; } = "2.0";
    [JsonPropertyName("id")] public JsonElement? Id { get; set; }
    [JsonPropertyName("result")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public object? Result { get; set; }
    [JsonPropertyName("error")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public JsonRpcError? Error { get; set; }
}

public class JsonRpcError
{
    [JsonPropertyName("code")] public int Code { get; set; }
    [JsonPropertyName("message")] public string Message { get; set; } = string.Empty;
}

public class A2AMessageSendParams
{
    [JsonPropertyName("message")] public A2AMessage Message { get; set; } = new();
}

public class A2AMessage
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "message";
    [JsonPropertyName("messageId")] public string MessageId { get; set; } = Guid.NewGuid().ToString("N");
    [JsonPropertyName("role")] public string Role { get; set; } = "user";
    [JsonPropertyName("parts")] public List<A2APart> Parts { get; set; } = [];
    [JsonPropertyName("contextId")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ContextId { get; set; }
}

public class A2APart
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "text";
    [JsonPropertyName("text")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Text { get; set; }
}
