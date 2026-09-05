using Microsoft.Extensions.Options;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

public record TextChunk(string Content, int? Page);

/// <summary>Splits page-oriented text into overlapping chunks sized by an approximate token budget.</summary>
public class ChunkingService
{
    // Rough heuristic: 1 token ~ 4 characters of English text.
    private const int CharsPerToken = 4;

    private readonly int _chunkSizeChars;
    private readonly int _overlapChars;

    public ChunkingService(IOptions<RagOptions> options)
    {
        _chunkSizeChars = Math.Max(200, options.Value.ChunkSizeTokens * CharsPerToken);
        _overlapChars = Math.Max(0, options.Value.ChunkOverlapTokens * CharsPerToken);
    }

    public IReadOnlyList<TextChunk> Chunk(IReadOnlyList<(string Text, int? Page)> pages)
    {
        var chunks = new List<TextChunk>();
        foreach (var (text, page) in pages)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }

            var start = 0;
            while (start < text.Length)
            {
                var length = Math.Min(_chunkSizeChars, text.Length - start);
                var end = start + length;

                // Prefer breaking on sentence or whitespace boundaries.
                if (end < text.Length)
                {
                    var window = text.AsSpan(start, length);
                    var breakAt = window.LastIndexOfAny('.', '\n');
                    if (breakAt > _chunkSizeChars / 2)
                    {
                        length = breakAt + 1;
                        end = start + length;
                    }
                }

                var content = text.Substring(start, length).Trim();
                if (content.Length > 0)
                {
                    chunks.Add(new TextChunk(content, page));
                }

                if (end >= text.Length)
                {
                    break;
                }

                start = Math.Max(start + 1, end - _overlapChars);
            }
        }

        return chunks;
    }
}
