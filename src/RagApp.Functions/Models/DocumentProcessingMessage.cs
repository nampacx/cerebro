namespace RagApp.Functions.Models;

/// <summary>
/// Queue message that hands ingestion context from the upload endpoint to the async
/// processing function. Explicit and queue-carried rather than read back from blob
/// metadata, because the classic blob-trigger's metadata-driven path depends on the
/// storage account's (now generally unavailable) classic analytics logs.
/// </summary>
public record DocumentProcessingMessage(Guid DocumentId, string OwnerOid, string Filename, string BlobName);
