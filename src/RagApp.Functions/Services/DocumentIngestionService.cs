using System.Text.Json;
using Azure;
using Azure.AI.DocumentIntelligence;
using Azure.Storage.Blobs;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Ingestion pipeline: store the raw document in Blob Storage, extract text with
/// the Foundry Document Intelligence read model, chunk, embed, and persist chunks
/// with citations and vectors under row-level security.
/// </summary>
public class DocumentIngestionService
{
    private readonly BlobServiceClient _blobServiceClient;
    private readonly DocumentIntelligenceClient _documentIntelligenceClient;
    private readonly ChunkingService _chunkingService;
    private readonly EmbeddingService _embeddingService;
    private readonly PgVectorStore _store;
    private readonly RagOptions _options;
    private readonly ILogger<DocumentIngestionService> _logger;

    public DocumentIngestionService(
        BlobServiceClient blobServiceClient,
        DocumentIntelligenceClient documentIntelligenceClient,
        ChunkingService chunkingService,
        EmbeddingService embeddingService,
        PgVectorStore store,
        IOptions<RagOptions> options,
        ILogger<DocumentIngestionService> logger)
    {
        _blobServiceClient = blobServiceClient;
        _documentIntelligenceClient = documentIntelligenceClient;
        _chunkingService = chunkingService;
        _embeddingService = embeddingService;
        _store = store;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<UploadResponse> IngestAsync(
        UserContext user,
        string filename,
        string? contentType,
        Stream content,
        IReadOnlyList<string> shareWithGroupIds,
        CancellationToken ct = default)
    {
        // 1. Upload the original document to blob storage, partitioned by owner.
        var containerClient = _blobServiceClient.GetBlobContainerClient(_options.DocumentsContainer);
        var blobName = $"{user.ObjectId}/{Guid.NewGuid():N}/{filename}";
        var blobClient = containerClient.GetBlobClient(blobName);

        using var memory = new MemoryStream();
        await content.CopyToAsync(memory, ct);
        memory.Position = 0;
        await blobClient.UploadAsync(memory, overwrite: false, ct);
        _logger.LogInformation("Uploaded {Filename} to {BlobUri}", filename, blobClient.Uri);

        // 2. Extract text with the Document Intelligence read model.
        memory.Position = 0;
        var analyzeOperation = await _documentIntelligenceClient.AnalyzeDocumentAsync(
            WaitUntil.Completed,
            new AnalyzeDocumentOptions("prebuilt-read", BinaryData.FromStream(memory)),
            ct);
        var analyzeResult = analyzeOperation.Value;

        var pages = ExtractPages(analyzeResult);

        // 3. Chunk.
        var textChunks = _chunkingService.Chunk(pages);
        if (textChunks.Count == 0)
        {
            throw new InvalidOperationException($"No text could be extracted from '{filename}'.");
        }

        // 4. Embed.
        var embeddings = await _embeddingService.EmbedBatchAsync(
            textChunks.Select(c => c.Content).ToList(), ct);

        // 5. Persist with citations under RLS.
        var chunkRecords = textChunks.Select((chunk, i) => new ChunkRecord(
            i,
            chunk.Content,
            JsonSerializer.Serialize(new
            {
                filename,
                page = chunk.Page,
                chunkIndex = i,
                blobUrl = blobClient.Uri.ToString()
            }),
            embeddings[i])).ToList();

        var documentId = await _store.InsertDocumentAsync(
            user, filename, blobClient.Uri.ToString(), contentType, shareWithGroupIds, chunkRecords, ct);

        _logger.LogInformation(
            "Ingested document {DocumentId} ({ChunkCount} chunks) for user {UserOid}",
            documentId, chunkRecords.Count, user.ObjectId);

        return new UploadResponse(documentId, filename, chunkRecords.Count);
    }

    private static List<(string Text, int? Page)> ExtractPages(AnalyzeResult result)
    {
        var pages = new List<(string Text, int? Page)>();
        if (result.Pages is { Count: > 0 })
        {
            foreach (var page in result.Pages)
            {
                var text = string.Join(
                    "\n", page.Lines?.Select(l => l.Content) ?? Enumerable.Empty<string>());
                pages.Add((text, page.PageNumber));
            }
        }
        else if (!string.IsNullOrEmpty(result.Content))
        {
            pages.Add((result.Content, null));
        }

        return pages;
    }
}
