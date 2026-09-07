using System.Text.Json;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Queues;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Synchronous part of ingestion: persists the raw document to Blob Storage and
/// records a pending row. Text extraction, chunking and embedding happen
/// asynchronously in <see cref="DocumentProcessingService"/>, driven by a queue trigger.
/// </summary>
public class DocumentUploadService
{
    private readonly BlobServiceClient _blobServiceClient;
    private readonly QueueServiceClient _queueServiceClient;
    private readonly PgVectorStore _store;
    private readonly RagOptions _options;
    private readonly ILogger<DocumentUploadService> _logger;

    public DocumentUploadService(
        BlobServiceClient blobServiceClient,
        QueueServiceClient queueServiceClient,
        PgVectorStore store,
        IOptions<RagOptions> options,
        ILogger<DocumentUploadService> logger)
    {
        _blobServiceClient = blobServiceClient;
        _queueServiceClient = queueServiceClient;
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

        // Record the pending document first so the row exists before processing can start.
        var documentId = await _store.CreatePendingDocumentAsync(
            user, filename, blobClient.Uri.ToString(), contentType, shareWithGroupIds, ct);

        try
        {
            await blobClient.UploadAsync(
                content,
                new BlobUploadOptions { HttpHeaders = new BlobHttpHeaders { ContentType = contentType } },
                ct);

            var queueClient = _queueServiceClient.GetQueueClient(_options.DocumentProcessingQueue);
            await queueClient.CreateIfNotExistsAsync(cancellationToken: ct);
            var message = new DocumentProcessingMessage(documentId, user.ObjectId, filename, blobName);
            // Plain text: host.json sets extensions.queues.messageEncoding to "none" to
            // match. The queue trigger extension defaults to base64 (for compatibility with
            // the Functions queue output binding, which base64-encodes automatically); this
            // raw QueueClient doesn't, so sending plain text against that default made the
            // listener fail to decode every message before it ever reached user code or got
            // logged — every message just silently retried five times and went to the
            // poison queue.
            await queueClient.SendMessageAsync(JsonSerializer.Serialize(message), ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Upload or enqueue failed for document {DocumentId}", documentId);
            await _store.UpdateStatusAsync(user, documentId, DocumentStatus.Failed, "Upload to storage failed.", ct);
            throw;
        }

        _logger.LogInformation(
            "Queued document {DocumentId} ({Filename}) for asynchronous processing", documentId, filename);

        return new UploadResponse(documentId, filename, DocumentStatus.Pending);
    }
}
