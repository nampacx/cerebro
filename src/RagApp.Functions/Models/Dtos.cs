namespace RagApp.Functions.Models;

public record DocumentInfo(Guid Id, string Filename, string BlobUrl, DateTimeOffset CreatedAt);

public record ChunkRecord(int Index, string Content, string CitationJson, float[] Embedding);

public record Citation(string Filename, int? Page, int ChunkIndex, string DocumentId);

public record SearchResult(Guid ChunkId, Guid DocumentId, string Content, string CitationJson, double Similarity);

public record ChatRequest(string Message, int TopK = 5);

public record ChatResponse(string Answer, IReadOnlyList<CitationResult> Citations);

public record CitationResult(string DocumentId, string Filename, int? Page, int ChunkIndex, string Snippet);

public record UploadResponse(Guid DocumentId, string Filename, int ChunkCount);
