using System.Text.Json;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RagApp.Functions.Models;
using RagApp.Functions.Services;

namespace RagApp.Functions.Functions;

/// <summary>
/// Queue-triggered asynchronous ingestion. <see cref="DocumentUploadService"/> enqueues
/// the ingestion context (owner, document id, blob name) as an explicit message rather
/// than relying on a blob trigger: the classic blob trigger's fast path depends on the
/// storage account's classic analytics logs, which aren't enabled by default and can
/// leave new blobs undetected for many minutes (or longer) on its fallback container scan.
/// </summary>
public class ProcessDocumentFunction
{
    private readonly BlobServiceClient _blobServiceClient;
    private readonly DocumentProcessingService _processingService;
    private readonly RagOptions _options;
    private readonly ILogger<ProcessDocumentFunction> _logger;

    public ProcessDocumentFunction(
        BlobServiceClient blobServiceClient,
        DocumentProcessingService processingService,
        IOptions<RagOptions> options,
        ILogger<ProcessDocumentFunction> logger)
    {
        _blobServiceClient = blobServiceClient;
        _processingService = processingService;
        _options = options.Value;
        _logger = logger;
    }

    [Function("ProcessDocument")]
    public async Task Run(
        // Hardcoded, not "%Rag:DocumentProcessingQueue%": the language-neutral Functions
        // host resolves trigger binding expressions itself, before the isolated worker
        // process starts, so it never sees Rag:* values that come from Azure App
        // Configuration (those are only loaded in this worker's Program.cs). Must match
        // RagOptions.DocumentProcessingQueue's default, which DocumentUploadService uses
        // to send to this queue.
        [QueueTrigger("document-processing", Connection = "AzureWebJobsStorage")] string messageText,
        CancellationToken ct)
    {
        var message = JsonSerializer.Deserialize<DocumentProcessingMessage>(messageText);
        if (message is null)
        {
            _logger.LogWarning("Could not deserialize document-processing message: {Message}", messageText);
            return;
        }

        var blobClient = _blobServiceClient
            .GetBlobContainerClient(_options.DocumentsContainer)
            .GetBlobClient(message.BlobName);

        _logger.LogInformation(
            "Processing blob {BlobName} as document {DocumentId}", message.BlobName, message.DocumentId);

        var download = await blobClient.DownloadStreamingAsync(cancellationToken: ct);
        await using var content = download.Value.Content;
        await _processingService.ProcessAsync(
            message.DocumentId, message.OwnerOid, message.Filename, blobClient.Uri.ToString(), content, ct);
    }
}
