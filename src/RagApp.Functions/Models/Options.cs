namespace RagApp.Functions.Models;

public class RagOptions
{
    public const string SectionName = "Rag";

    public string OpenAiEndpoint { get; set; } = string.Empty;
    public string DocumentIntelligenceEndpoint { get; set; } = string.Empty;
    public string ChatDeployment { get; set; } = "gpt-5";
    public string EmbeddingDeployment { get; set; } = "text-embedding-3-large";
    public int EmbeddingDimensions { get; set; } = 1536;
    public string PostgresHost { get; set; } = string.Empty;
    public string PostgresDatabase { get; set; } = "ragdb";
    /// <summary>Postgres role name; defaults to the function app name (managed identity principal).</summary>
    public string? PostgresUser { get; set; }
    public string BlobEndpoint { get; set; } = string.Empty;
    public string DocumentsContainer { get; set; } = "documents";
    public int ChunkSizeTokens { get; set; } = 512;
    public int ChunkOverlapTokens { get; set; } = 64;
}

public class AuthOptions
{
    public const string SectionName = "Auth";

    public string TenantId { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
}
