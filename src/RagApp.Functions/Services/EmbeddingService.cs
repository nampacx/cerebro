using Azure.AI.OpenAI;
using Microsoft.Extensions.Options;
using OpenAI.Embeddings;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

public class EmbeddingService
{
    private readonly EmbeddingClient _client;

    public EmbeddingService(AzureOpenAIClient openAiClient, IOptions<RagOptions> options)
    {
        _client = openAiClient.GetEmbeddingClient(options.Value.EmbeddingDeployment);
    }

    public async Task<float[]> EmbedAsync(string text, CancellationToken ct = default)
    {
        var embedding = await _client.GenerateEmbeddingAsync(text, cancellationToken: ct);
        return embedding.Value.ToFloats().ToArray();
    }

    public async Task<IReadOnlyList<float[]>> EmbedBatchAsync(IReadOnlyList<string> texts, CancellationToken ct = default)
    {
        var response = await _client.GenerateEmbeddingsAsync(texts, cancellationToken: ct);
        return response.Value.Select(e => e.ToFloats().ToArray()).ToList();
    }
}
