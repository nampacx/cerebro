namespace RagApp.Functions.Models;

public class RagOptions
{
    public const string SectionName = "Rag";

    public string OpenAiEndpoint { get; set; } = string.Empty;
    /// <summary>Project-scoped Foundry endpoint (`https://{account}.services.ai.azure.com/api/projects/{project}`), required for the conversations API to reach the project's BYO Cosmos DB thread storage.</summary>
    public string FoundryProjectEndpoint { get; set; } = string.Empty;
    public string DocumentIntelligenceEndpoint { get; set; } = string.Empty;
    public string ChatDeployment { get; set; } = "gpt-5";
    public string EmbeddingDeployment { get; set; } = "text-embedding-3-large";
    public int EmbeddingDimensions { get; set; } = 1536;
    public string PostgresHost { get; set; } = string.Empty;
    public string PostgresDatabase { get; set; } = "ragdb";
    /// <summary>Postgres role name; defaults to the function app name (managed identity principal).</summary>
    public string? PostgresUser { get; set; }
    public string BlobEndpoint { get; set; } = string.Empty;
    public string QueueEndpoint { get; set; } = string.Empty;
    public string DocumentsContainer { get; set; } = "documents";
    /// <summary>Must match the literal queue name in ProcessDocumentFunction's [QueueTrigger] — that attribute can't reference this App-Configuration-sourced value (see the comment there).</summary>
    public string DocumentProcessingQueue { get; set; } = "document-processing";
    public int ChunkSizeTokens { get; set; } = 512;
    public int ChunkOverlapTokens { get; set; } = 64;
}

public class AuthOptions
{
    public const string SectionName = "Auth";

    public string TenantId { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
}
