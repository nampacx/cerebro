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

    public async Task<Guid> CreatePendingDocumentAsync(
        UserContext user,
        string filename,
        string blobUrl,
        string? contentType,
        IReadOnlyList<string> shareWithGroupIds,
        CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        Guid documentId;
        await using (var cmd = new NpgsqlCommand(
            """
            INSERT INTO documents (owner_oid, filename, blob_url, content_type, status)
            VALUES (@owner, @filename, @blobUrl, @contentType, 'pending')
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

        await tx.CommitAsync(ct);
        return documentId;
    }

    /// <summary>Persists the chunks produced by the async processor and marks the document completed.</summary>
    public async Task AddChunksAsync(
        UserContext owner,
        Guid documentId,
        IReadOnlyList<ChunkRecord> chunks,
        CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, owner, ct);

        // Make reprocessing idempotent.
        await using (var deleteCmd = new NpgsqlCommand(
            "DELETE FROM chunks WHERE document_id = @doc", conn, tx))
        {
            deleteCmd.Parameters.AddWithValue("doc", documentId);
            await deleteCmd.ExecuteNonQueryAsync(ct);
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

        await using (var statusCmd = new NpgsqlCommand(
            """
            UPDATE documents
            SET status = 'completed', chunk_count = @count, error_message = NULL, updated_at = now()
            WHERE id = @doc
            """, conn, tx))
        {
            statusCmd.Parameters.AddWithValue("doc", documentId);
            statusCmd.Parameters.AddWithValue("count", chunks.Count);
            await statusCmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }

    public async Task UpdateStatusAsync(
        UserContext owner, Guid documentId, string status, string? errorMessage = null, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, owner, ct);

        await using var cmd = new NpgsqlCommand(
            "UPDATE documents SET status = @status, error_message = @error, updated_at = now() WHERE id = @doc",
            conn, tx);
        cmd.Parameters.AddWithValue("doc", documentId);
        cmd.Parameters.AddWithValue("status", status);
        cmd.Parameters.AddWithValue("error", (object?)errorMessage ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);

        await tx.CommitAsync(ct);
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
            """
            SELECT id, filename, blob_url, status, error_message, chunk_count, created_at, updated_at
            FROM documents
            ORDER BY created_at DESC
            """, conn, tx);

        var results = new List<DocumentInfo>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            results.Add(new DocumentInfo(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.IsDBNull(4) ? null : reader.GetString(4),
                reader.GetInt32(5),
                reader.GetFieldValue<DateTimeOffset>(6),
                reader.GetFieldValue<DateTimeOffset>(7)));
        }

        return results;
    }

    /// <summary>Records a new Foundry conversation, or renames an existing one owned by the caller.</summary>
    public async Task AddConversationAsync(UserContext user, string conversationId, string title, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand(
            """
            INSERT INTO conversations (id, owner_oid, title)
            VALUES (@id, @owner, @title)
            ON CONFLICT (id) DO UPDATE SET title = EXCLUDED.title, updated_at = now()
            """, conn, tx);
        cmd.Parameters.AddWithValue("id", conversationId);
        cmd.Parameters.AddWithValue("owner", user.ObjectId);
        cmd.Parameters.AddWithValue("title", title);
        await cmd.ExecuteNonQueryAsync(ct);

        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// True when a conversation with this id is visible to the caller. This is the
    /// authorization boundary for chat history - RLS means a row is only visible when
    /// conversations.owner_oid matches the caller, so this doubles as an existence check:
    /// another user's conversation id looks identical to a nonexistent one.
    /// </summary>
    public async Task<bool> OwnsConversationAsync(UserContext user, string conversationId, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand("SELECT 1 FROM conversations WHERE id = @id", conn, tx);
        cmd.Parameters.AddWithValue("id", conversationId);
        return await cmd.ExecuteScalarAsync(ct) is not null;
    }

    public async Task TouchConversationAsync(UserContext user, string conversationId, string? title = null, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand(
            """
            UPDATE conversations
            SET updated_at = now(), title = COALESCE(@title, title)
            WHERE id = @id
            """, conn, tx);
        cmd.Parameters.AddWithValue("id", conversationId);
        cmd.Parameters.AddWithValue("title", (object?)title ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);

        await tx.CommitAsync(ct);
    }

    public async Task<IReadOnlyList<ConversationSummary>> ListConversationsAsync(UserContext user, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand(
            "SELECT id, title, created_at, updated_at FROM conversations ORDER BY updated_at DESC", conn, tx);

        var results = new List<ConversationSummary>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            results.Add(new ConversationSummary(
                reader.GetString(0),
                reader.GetString(1),
                reader.GetFieldValue<DateTimeOffset>(2),
                reader.GetFieldValue<DateTimeOffset>(3)));
        }

        return results;
    }

    public async Task DeleteConversationAsync(UserContext user, string conversationId, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await SetUserContextAsync(conn, tx, user, ct);

        await using var cmd = new NpgsqlCommand("DELETE FROM conversations WHERE id = @id", conn, tx);
        cmd.Parameters.AddWithValue("id", conversationId);
        await cmd.ExecuteNonQueryAsync(ct);

        await tx.CommitAsync(ct);
    }

    public ValueTask DisposeAsync() => _dataSource.DisposeAsync();
}
