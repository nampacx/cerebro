using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using RagApp.Functions.Services;

namespace RagApp.Functions.Functions;

/// <summary>
/// Blob-triggered asynchronous ingestion. Fires when the upload endpoint writes a
/// document, then extracts, chunks, embeds and stores it. The ingestion context
/// (owner, document id) travels with the blob metadata.
/// </summary>
public class ProcessDocumentFunction
{
    private readonly DocumentProcessingService _processingService;
    private readonly ILogger<ProcessDocumentFunction> _logger;

    public ProcessDocumentFunction(
        DocumentProcessingService processingService,
        ILogger<ProcessDocumentFunction> logger)
    {
        _processingService = processingService;
        _logger = logger;
    }

    [Function("ProcessDocument")]
    public async Task Run(
        [BlobTrigger("documents/{name}", Connection = "AzureWebJobsStorage")] Stream content,
        string name,
        IDictionary<string, string>? metadata,
        Uri uri,
        CancellationToken ct)
    {
        metadata ??= new Dictionary<string, string>();

        if (!metadata.TryGetValue(DocumentUploadService.DocumentIdMetadataKey, out var documentIdValue) ||
            !Guid.TryParse(documentIdValue, out var documentId))
        {
            _logger.LogWarning("Blob {Name} has no valid documentId metadata; skipping.", name);
            return;
        }

        if (!metadata.TryGetValue(DocumentUploadService.OwnerOidMetadataKey, out var ownerOid) ||
            string.IsNullOrWhiteSpace(ownerOid))
        {
            _logger.LogWarning("Blob {Name} has no ownerOid metadata; skipping.", name);
            return;
        }

        var filename = metadata.TryGetValue(DocumentUploadService.FilenameMetadataKey, out var f) && !string.IsNullOrEmpty(f)
            ? f
            : name.Split('/').Last();

        _logger.LogInformation("Processing blob {Name} as document {DocumentId}", name, documentId);
        await _processingService.ProcessAsync(documentId, ownerOid, filename, uri.ToString(), content, ct);
    }
}
