namespace RagApp.Functions.Models;

public record DocumentInfo(
    Guid Id,
    string Filename,
    string BlobUrl,
    string Status,
    string? ErrorMessage,
    int ChunkCount,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt);

public record ChunkRecord(int Index, string Content, string CitationJson, float[] Embedding);

public record Citation(string Filename, int? Page, int ChunkIndex, string DocumentId);

public record SearchResult(Guid ChunkId, Guid DocumentId, string Content, string CitationJson, double Similarity);

public record ChatRequest(string Message, int TopK = 5, string? ConversationId = null);

public record ChatResponse(string Answer, IReadOnlyList<CitationResult> Citations, string ConversationId);

public record CitationResult(string DocumentId, string Filename, int? Page, int ChunkIndex, string Snippet);

/// <summary>Returned by the upload endpoint; ingestion continues asynchronously via the blob trigger.</summary>
public record UploadResponse(Guid DocumentId, string Filename, string Status);

public record ConversationSummary(string Id, string Title, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

public record ConversationMessage(string Role, string Text, DateTimeOffset? CreatedAt);

public record CreateConversationRequest(string? Title);

public static class DocumentStatus
{
    public const string Pending = "pending";
    public const string Processing = "processing";
    public const string Completed = "completed";
    public const string Failed = "failed";
}
