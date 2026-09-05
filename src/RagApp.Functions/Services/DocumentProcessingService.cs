using System.Text.Json;
using Azure;
using Azure.AI.DocumentIntelligence;
using Microsoft.Extensions.Logging;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Asynchronous part of ingestion, executed by the blob trigger: read the document
/// with Foundry Document Intelligence, chunk it, generate embeddings and persist the
/// chunks with citations.
///
/// The trigger runs under the function app's managed identity, but all writes still go
/// through row-level security: the owner's Entra object id is recovered from the blob
/// metadata and used as the RLS session context, so nothing bypasses the policies.
/// </summary>
public class DocumentProcessingService
{
    private readonly DocumentIntelligenceClient _documentIntelligenceClient;
    private readonly ChunkingService _chunkingService;
    private readonly EmbeddingService _embeddingService;
    private readonly PgVectorStore _store;
    private readonly ILogger<DocumentProcessingService> _logger;

    public DocumentProcessingService(
        DocumentIntelligenceClient documentIntelligenceClient,
        ChunkingService chunkingService,
        EmbeddingService embeddingService,
        PgVectorStore store,
        ILogger<DocumentProcessingService> logger)
    {
        _documentIntelligenceClient = documentIntelligenceClient;
        _chunkingService = chunkingService;
        _embeddingService = embeddingService;
        _store = store;
        _logger = logger;
    }

    public async Task ProcessAsync(
        Guid documentId,
        string ownerOid,
        string filename,
        string blobUrl,
        Stream content,
        CancellationToken ct = default)
    {
        // The owner has no group memberships in this context; only owner-scoped
        // insert/update policies are needed to write the document's own chunks.
        var ownerContext = new UserContext(ownerOid, [], null);

        try
        {
            await _store.UpdateStatusAsync(ownerContext, documentId, DocumentStatus.Processing, null, ct);

            using var buffer = new MemoryStream();
            await content.CopyToAsync(buffer, ct);
            buffer.Position = 0;

            var analyzeOperation = await _documentIntelligenceClient.AnalyzeDocumentAsync(
                WaitUntil.Completed,
                new AnalyzeDocumentOptions("prebuilt-read", BinaryData.FromStream(buffer)),
                ct);

            var pages = ExtractPages(analyzeOperation.Value);
            var textChunks = _chunkingService.Chunk(pages);
            if (textChunks.Count == 0)
            {
                await _store.UpdateStatusAsync(
                    ownerContext, documentId, DocumentStatus.Failed, "No text could be extracted from the document.", ct);
                return;
            }

            var embeddings = await _embeddingService.EmbedBatchAsync(
                textChunks.Select(c => c.Content).ToList(), ct);

            var chunkRecords = textChunks.Select((chunk, i) => new ChunkRecord(
                i,
                chunk.Content,
                JsonSerializer.Serialize(new
                {
                    filename,
                    page = chunk.Page,
                    chunkIndex = i,
                    blobUrl
                }),
                embeddings[i])).ToList();

            await _store.AddChunksAsync(ownerContext, documentId, chunkRecords, ct);

            _logger.LogInformation(
                "Processed document {DocumentId}: {ChunkCount} chunks stored for owner {OwnerOid}",
                documentId, chunkRecords.Count, ownerOid);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Processing failed for document {DocumentId}", documentId);
            await _store.UpdateStatusAsync(
                ownerContext, documentId, DocumentStatus.Failed, Truncate(ex.Message, 500), CancellationToken.None);
            throw;
        }
    }

    private static string Truncate(string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];

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
