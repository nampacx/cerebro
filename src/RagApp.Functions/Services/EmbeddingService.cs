using Azure.AI.OpenAI;
using Microsoft.Extensions.Options;
using OpenAI.Embeddings;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

public class EmbeddingService
{
    private readonly EmbeddingClient _client;
    private readonly EmbeddingGenerationOptions _options;

    public EmbeddingService(AzureOpenAIClient openAiClient, IOptions<RagOptions> options)
    {
        _client = openAiClient.GetEmbeddingClient(options.Value.EmbeddingDeployment);
        // text-embedding-3-* models emit their native dimension (3072 for -large) unless
        // explicitly truncated here; without this, pgvector's fixed-width vector(1536)
        // column rejects every insert with "expected 1536 dimensions, not 3072".
        _options = new EmbeddingGenerationOptions { Dimensions = options.Value.EmbeddingDimensions };
    }

    public async Task<float[]> EmbedAsync(string text, CancellationToken ct = default)
    {
        var embedding = await _client.GenerateEmbeddingAsync(text, _options, ct);
        return embedding.Value.ToFloats().ToArray();
    }

    public async Task<IReadOnlyList<float[]>> EmbedBatchAsync(IReadOnlyList<string> texts, CancellationToken ct = default)
    {
        var response = await _client.GenerateEmbeddingsAsync(texts, _options, ct);
        return response.Value.Select(e => e.ToFloats().ToArray()).ToList();
    }
}
