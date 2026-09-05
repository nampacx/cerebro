using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Options;
using RagApp.Functions.Models;

namespace RagApp.Functions.Services;

/// <summary>
/// Azure Table index mapping users to their Foundry conversation ids.
///
/// This is the authorization boundary for chat history: a conversation can only be
/// read, continued or deleted when an entry exists under the caller's own partition,
/// so one user can never resume another user's Foundry conversation.
/// </summary>
public class ConversationIndex
{
    private readonly TableClient _tableClient;

    public ConversationIndex(TableServiceClient tableServiceClient, IOptions<RagOptions> options)
    {
        _tableClient = tableServiceClient.GetTableClient(options.Value.ConversationsTable);
    }

    private async Task EnsureTableAsync(CancellationToken ct) =>
        await _tableClient.CreateIfNotExistsAsync(ct);

    public async Task AddAsync(string userOid, string conversationId, string title, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        var now = DateTimeOffset.UtcNow;
        var entity = new TableEntity(userOid, conversationId)
        {
            ["Title"] = title,
            ["CreatedAt"] = now,
            ["UpdatedAt"] = now
        };
        await _tableClient.UpsertEntityAsync(entity, TableUpdateMode.Replace, ct);
    }

    public async Task<bool> OwnsAsync(string userOid, string conversationId, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        try
        {
            await _tableClient.GetEntityAsync<TableEntity>(userOid, conversationId, cancellationToken: ct);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return false;
        }
    }

    public async Task TouchAsync(string userOid, string conversationId, string? title = null, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        try
        {
            var response = await _tableClient.GetEntityAsync<TableEntity>(userOid, conversationId, cancellationToken: ct);
            var entity = response.Value;
            entity["UpdatedAt"] = DateTimeOffset.UtcNow;
            if (!string.IsNullOrWhiteSpace(title))
            {
                entity["Title"] = title;
            }

            await _tableClient.UpdateEntityAsync(entity, entity.ETag, TableUpdateMode.Replace, ct);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            // Nothing to touch.
        }
    }

    public async Task<IReadOnlyList<ConversationSummary>> ListAsync(string userOid, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        var results = new List<ConversationSummary>();
        var query = _tableClient.QueryAsync<TableEntity>(
            e => e.PartitionKey == userOid, cancellationToken: ct);

        await foreach (var entity in query)
        {
            results.Add(new ConversationSummary(
                entity.RowKey,
                entity.GetString("Title") ?? "Untitled conversation",
                entity.GetDateTimeOffset("CreatedAt") ?? entity.Timestamp ?? DateTimeOffset.UtcNow,
                entity.GetDateTimeOffset("UpdatedAt") ?? entity.Timestamp ?? DateTimeOffset.UtcNow));
        }

        return results.OrderByDescending(c => c.UpdatedAt).ToList();
    }

    public async Task DeleteAsync(string userOid, string conversationId, CancellationToken ct = default)
    {
        await EnsureTableAsync(ct);
        await _tableClient.DeleteEntityAsync(userOid, conversationId, ETag.All, ct);
    }
}
