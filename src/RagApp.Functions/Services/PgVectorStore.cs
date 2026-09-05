using System.Text.Json;
using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Options;
using Npgsql;
using Pgvector;
using Pgvector.Npgsql;
using RagApp.Functions.Auth;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// PostgreSQL + pgvector data access. Connects with the function app's managed
/// identity (Entra token as password) as a non-privileged role, and sets the
/// caller identity via SET LOCAL so native row-level security policies apply.
/// </summary>
public class PgVectorStore : IAsyncDisposable
{
    private static readonly string[] TokenScope = ["https://ossrdbms-aad.database.windows.net/.default"];

    private readonly NpgsqlDataSource _dataSource;

    public PgVectorStore(IOptions<RagOptions> options, TokenCredential credential)
    {
        var o = options.Value;
        var user = o.PostgresUser
                   ?? Environment.GetEnvironmentVariable("WEBSITE_SITE_NAME")
                   ?? throw new InvalidOperationException("Rag:PostgresUser is not configured.");

        var builder = new NpgsqlDataSourceBuilder(new NpgsqlConnectionStringBuilder
        {
            Host = o.PostgresHost,
            Database = o.PostgresDatabase,
            Username = user,
            SslMode = SslMode.Require
        }.ConnectionString);

        builder.UsePeriodicPasswordProvider(
            async (_, ct) =>
                (await credential.GetTokenAsync(new TokenRequestContext(TokenScope), ct)).Token,
            TimeSpan.FromMinutes(45),
            TimeSpan.FromSeconds(5));
        builder.UseVector();
        _dataSource = builder.Build();
    }

    private static async Task SetUserContextAsync(NpgsqlConnection conn, NpgsqlTransaction tx, UserContext user, CancellationToken ct)
    {
        // set_config with is_local=true scopes the settings to the transaction (SET LOCAL).
        await using var cmd = new NpgsqlCommand(
            "SELECT set_config('app.user_oid', @oid, true), set_config('app.groups', @groups, true)", conn, tx);
        cmd.Parameters.AddWithValue("oid", user.ObjectId);
        cmd.Parameters.AddWithValue("groups", string.Join(',', user.GroupIds));
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Guid> InsertDocumentAsync(
        UserContext user,
        string filename,
        string blobUrl,
        string? contentType,
        IReadOnlyList<string> shareWithGroupIds,
        IReadOnlyList<ChunkRecord> chunks,
        CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        Guid documentId;
        await using (var cmd = new NpgsqlCommand(
            """
            INSERT INTO documents (owner_oid, filename, blob_url, content_type)
            VALUES (@owner, @filename, @blobUrl, @contentType)
            RETURNING id
            """, conn, tx))
        {
            cmd.Parameters.AddWithValue("owner", user.ObjectId);
            cmd.Parameters.AddWithValue("filename", filename);
            cmd.Parameters.AddWithValue("blobUrl", blobUrl);
            cmd.Parameters.AddWithValue("contentType", (object?)contentType ?? DBNull.Value);
            documentId = (Guid)(await cmd.ExecuteScalarAsync(ct))!;
        }

        foreach (var groupId in shareWithGroupIds)
        {
            await using var aclCmd = new NpgsqlCommand(
                "INSERT INTO document_acl (document_id, group_oid) VALUES (@doc, @grp)", conn, tx);
            aclCmd.Parameters.AddWithValue("doc", documentId);
            aclCmd.Parameters.AddWithValue("grp", groupId);
            await aclCmd.ExecuteNonQueryAsync(ct);
        }

        foreach (var chunk in chunks)
        {
            await using var chunkCmd = new NpgsqlCommand(
                """
                INSERT INTO chunks (document_id, chunk_index, content, citation, embedding)
                VALUES (@doc, @idx, @content, @citation::jsonb, @embedding)
                """, conn, tx);
            chunkCmd.Parameters.AddWithValue("doc", documentId);
            chunkCmd.Parameters.AddWithValue("idx", chunk.Index);
            chunkCmd.Parameters.AddWithValue("content", chunk.Content);
            chunkCmd.Parameters.AddWithValue("citation", chunk.CitationJson);
            chunkCmd.Parameters.AddWithValue("embedding", new Vector(chunk.Embedding));
            await chunkCmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return documentId;
    }

    public async Task<IReadOnlyList<SearchResult>> SearchAsync(
        UserContext user, float[] queryEmbedding, int topK, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        // RLS policies filter chunks to those the caller may see.
        await using var cmd = new NpgsqlCommand(
            """
            SELECT id, document_id, content, citation::text,
                   1 - (embedding <=> @query) AS similarity
            FROM chunks
            ORDER BY embedding <=> @query
            LIMIT @topK
            """, conn, tx);
        cmd.Parameters.AddWithValue("query", new Vector(queryEmbedding));
        cmd.Parameters.AddWithValue("topK", topK);

        var results = new List<SearchResult>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            results.Add(new SearchResult(
                reader.GetGuid(0),
                reader.GetGuid(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetDouble(4)));
        }

        return results;
    }

    public async Task<IReadOnlyList<DocumentInfo>> ListDocumentsAsync(UserContext user, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand(
            "SELECT id, filename, blob_url, created_at FROM documents ORDER BY created_at DESC", conn, tx);

        var results = new List<DocumentInfo>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            results.Add(new DocumentInfo(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetFieldValue<DateTimeOffset>(3)));
        }

        return results;
    }

    public ValueTask DisposeAsync() => _dataSource.DisposeAsync();
}
