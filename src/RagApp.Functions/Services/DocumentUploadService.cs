using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Synchronous part of ingestion: persists the raw document to Blob Storage and
/// records a pending row. Text extraction, chunking and embedding happen
/// asynchronously in <see cref="DocumentProcessingService"/>, driven by a blob trigger.
/// </summary>
public class DocumentUploadService
{
    /// <summary>Blob metadata keys used to carry the ingestion context to the blob trigger.</summary>
    public const string OwnerOidMetadataKey = "ownerOid";
    public const string DocumentIdMetadataKey = "documentId";
    public const string GroupIdsMetadataKey = "groupIds";
    public const string FilenameMetadataKey = "originalFilename";

    private readonly BlobServiceClient _blobServiceClient;
    private readonly PgVectorStore _store;
    private readonly RagOptions _options;
    private readonly ILogger<DocumentUploadService> _logger;

    public DocumentUploadService(
        BlobServiceClient blobServiceClient,
        PgVectorStore store,
        IOptions<RagOptions> options,
        ILogger<DocumentUploadService> logger)
    {
        _blobServiceClient = blobServiceClient;
        _store = store;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<UploadResponse> UploadAsync(
        UserContext user,
        string filename,
        string? contentType,
        Stream content,
        IReadOnlyList<string> shareWithGroupIds,
        CancellationToken ct = default)
    {
        var containerClient = _blobServiceClient.GetBlobContainerClient(_options.DocumentsContainer);
        var blobName = $"{user.ObjectId}/{Guid.NewGuid():N}/{filename}";
        var blobClient = containerClient.GetBlobClient(blobName);

        // Record the pending document first so the row exists before the trigger fires.
        var documentId = await _store.CreatePendingDocumentAsync(
            user, filename, blobClient.Uri.ToString(), contentType, shareWithGroupIds, ct);

        var metadata = new Dictionary<string, string>
        {
            [OwnerOidMetadataKey] = user.ObjectId,
            [DocumentIdMetadataKey] = documentId.ToString(),
            [GroupIdsMetadataKey] = string.Join(',', shareWithGroupIds),
            [FilenameMetadataKey] = filename
        };

        try
        {
            await blobClient.UploadAsync(
                content,
                new BlobUploadOptions
                {
                    Metadata = metadata,
                    HttpHeaders = new BlobHttpHeaders { ContentType = contentType }
                },
                ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Blob upload failed for document {DocumentId}", documentId);
            await _store.UpdateStatusAsync(user, documentId, DocumentStatus.Failed, "Upload to storage failed.", ct);
            throw;
        }

        _logger.LogInformation(
            "Queued document {DocumentId} ({Filename}) for asynchronous processing", documentId, filename);

        return new UploadResponse(documentId, filename, DocumentStatus.Pending);
    }
}
