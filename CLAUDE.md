# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Cerebro** — an enterprise RAG platform on Azure: documents are chunked and embedded into PostgreSQL `pgvector`, and **every** query is filtered by native PostgreSQL row-level security keyed on the calling user's Entra ID `oid`/`groups` claims. Deployed with `azd` as two services declared in [azure.yaml](azure.yaml): `api` (Azure Functions, .NET 10 isolated) and `web` (React + Vite on Static Web Apps).

## Commands

```bash
# Backend build (from src/RagApp.Functions)
dotnet build
func start                    # needs local.settings.json — copy from local.settings.sample.json

# Web client (from src/web)
npm install
npm run dev                   # runs scripts/generate-config.mjs, then vite
npm run build                 # generate-config + tsc -b + vite build
```

```powershell
# Full provision + deploy + database schema (creates app registration, azd env, runs azd up)
./scripts/setup.ps1 -EnvironmentName cerebro-dev

# Redeploy one service after code changes
azd deploy api
azd deploy web

# Re-apply db/schema.sql (and the managed-identity role) without touching infra or app code,
# e.g. after editing the schema. Needs psql on PATH.
./scripts/setup.ps1 -EnvironmentName cerebro-dev -DatabaseOnly
```

There is **no test project, solution file, or linter config** in this repo — `dotnet build` and `tsc -b` are the only automated checks. Don't invent test commands; if verification is needed, say what was and wasn't verified.

## The RLS invariant

This is the central design constraint; most other decisions follow from it.

- The function app connects to PostgreSQL as a **non-privileged Entra role** (its managed identity name), so `FORCE ROW LEVEL SECURITY` in [db/schema.sql](db/schema.sql) applies to it.
- [Services/PgVectorStore.cs](src/RagApp.Functions/Services/PgVectorStore.cs) is the **only** database access point. Every method opens a transaction and calls `SetUserContextAsync`, which runs `set_config('app.user_oid'/'app.groups', …, true)` (transaction-scoped) from a validated `UserContext`. The policies in `db/schema.sql` read those settings via `app_current_user_oid()` / `app_current_groups()`.
- **New queries go in `PgVectorStore` and take a `UserContext`.** A query that skips `SetUserContextAsync`, or a connection opened elsewhere, silently returns zero rows or bypasses the security model.
- Vector similarity search is filtered by the same policies — there is no separate ACL check in application code for retrieval.

`UserContext` comes only from [Auth/EntraTokenValidator.cs](src/RagApp.Functions/Auth/EntraTokenValidator.cs). Every HTTP function starts with `ValidateAsync` and returns `UnauthorizedResult` on null. `AuthorizationLevel.Anonymous` on the triggers is deliberate: Easy Auth (`authsettingsV2`, configured in [infra/modules/function.bicep](infra/modules/function.bicep)) rejects unauthenticated requests at the platform edge, and the code independently validates the JWT to extract the claims RLS needs.

## Request flows

**Ingestion is split across two processes** and the ingestion context travels through an explicit queue message, not blob metadata:

1. [Services/DocumentUploadService.cs](src/RagApp.Functions/Services/DocumentUploadService.cs) — writes the `pending` row *before* uploading the blob (so the row exists when processing picks it up), uploads the blob, then sends a `DocumentProcessingMessage` (documentId/ownerOid/filename/blobName) to the `document-processing` storage queue, returns `202`.
2. [Functions/ProcessDocumentFunction.cs](src/RagApp.Functions/Functions/ProcessDocumentFunction.cs) → [Services/DocumentProcessingService.cs](src/RagApp.Functions/Services/DocumentProcessingService.cs) — a `[QueueTrigger]` (not `[BlobTrigger]`) runs under the *app* identity but reconstructs `new UserContext(ownerOid, [], null)` from the message, so writes still pass owner-scoped RLS policies. Status transitions `pending → processing → completed|failed`; `AddChunksAsync` deletes existing chunks first, making reprocessing idempotent.

The queue name is hardcoded (`"document-processing"`) as a literal in `[QueueTrigger]`, not `%Rag:DocumentProcessingQueue%`: the language-neutral Functions host resolves trigger binding expressions before the isolated worker process starts, so it can never see `Rag:*` values sourced from Azure App Configuration (only `Program.cs` in the worker loads those). `RagOptions.DocumentProcessingQueue` (used by the producer side) must keep matching that literal. This is also why `[BlobTrigger]` used to hardcode `"documents"` instead of referencing `Rag:DocumentsContainer`.

A classic `[BlobTrigger]` was tried first and dropped: its fast path depends on the storage account's classic Storage Analytics logs, which aren't enabled by default on new accounts, so its fallback container-scan alone left new blobs undetected for many minutes or longer in practice.

`host.json` sets `extensions:queues:messageEncoding` to `"none"`. The queue trigger extension defaults to expecting base64-encoded message bodies (for compatibility with the Functions queue *output binding*, which base64-encodes automatically); `DocumentUploadService` sends plain-text JSON through a raw `QueueClient` that doesn't, and that mismatch has no visible failure mode — the listener fails to decode the message before it reaches user code or any logger, so nothing appears in Application Insights beyond a `MaxDequeueCount` warning once the message is poisoned. If a producer and `host.json` ever disagree on this setting again, expect exactly that: silent poison-queue messages with no exception anywhere.

**Chat** goes through [Services/ChatOrchestrator.cs](src/RagApp.Functions/Services/ChatOrchestrator.cs):

- Chat history lives in **Foundry conversations** ([Services/FoundryConversationService.cs](src/RagApp.Functions/Services/FoundryConversationService.cs), raw `/openai/v1/conversations` HTTP calls), persisted in a customer-managed Cosmos DB. Foundry does **not** enforce per-user ownership — the Azure Table index in [Services/ConversationIndex.cs](src/RagApp.Functions/Services/ConversationIndex.cs) (`PartitionKey` = user oid) is the authorization boundary. Any path that accepts a caller-supplied conversation id must go through `OwnsAsync` first.
- [Services/RagAgentService.cs](src/RagApp.Functions/Services/RagAgentService.cs) builds a **per-request** Agent Framework agent. The `search_documents` tool is a local function that closes over the request's `UserContext` and accumulates citations as a side effect — that closure is how user identity reaches retrieval, so the agent cannot be hoisted to a singleton.

**A2A** ([A2A/A2AFunctions.cs](src/RagApp.Functions/A2A/A2AFunctions.cs)) reuses the same orchestrator and validator. Partner agents present an on-behalf-of token carrying the *end user's* claims; the JSON-RPC `contextId` is the conversation id and goes through the same ownership check.

## Configuration

`RagOptions` / `AuthOptions` ([Models/Options.cs](src/RagApp.Functions/Models/Options.cs)) bind the `Rag:` and `Auth:` sections.

- **In Azure**, `Rag:*` values come from App Configuration (with Key Vault references), loaded in [Program.cs](src/RagApp.Functions/Program.cs). To change one, edit the `keyValues` array in the `appConfig` module block of [infra/main.bicep](infra/main.bicep) — not the function app settings. `Auth__TenantId` / `Auth__ClientId` *are* function app settings, set via `additionalAppSettings`.
- **Locally**, everything comes from `local.settings.json` using `__` separators (see `local.settings.sample.json`). Set `Rag__PostgresUser` to your own Entra UPN; `DefaultAzureCredential` uses your `az login` identity.
- The embedding dimension is coupled in **three places** that must agree: `vector(1536)` in `db/schema.sql`, `Rag:EmbeddingDimensions` in App Configuration, and the `embeddingDimensions` param in `infra/main.bicep`.

Web client config is **generated, not authored**: `npm run build` runs [src/web/scripts/generate-config.mjs](src/web/scripts/generate-config.mjs), which writes `public/config.json` and `public/staticwebapp.config.json` from azd environment variables (falling back to `VITE_*`). Both outputs are git-ignored — edit the generator or [staticwebapp.config.template.json](src/web/staticwebapp.config.template.json) instead.

The SPA authenticates twice by necessity ([src/web/src/auth.ts](src/web/src/auth.ts)): Static Web Apps built-in Entra auth gates the site (`/.auth/me`) but does not issue downstream API tokens, so MSAL does a silent SSO for `api://<client-id>/access_as_user` before calling the Function App.

## Gotchas

- **Windows long paths**: the Functions build emits deeply nested `obj/.../WorkerExtensions/...` paths and can fail with `MSB3030` if the repo path is long. Build from a shorter path or enable Win32 long paths.
- Default `PUBLIC_NETWORK_ACCESS=Disabled` puts every backing service behind private endpoints. PostgreSQL is the one that matters for local tooling: `setup.ps1`'s `Initialize-Database` (step 7, also driven by `-DatabaseOnly`) checks the *live* server's current network state, temporarily flips it to `Enabled` with a firewall rule scoped to the caller's IP via `az postgres flexible-server update --public-access`, runs `setup-database.ps1`, then restores `Disabled` in a `finally` block — so `azd up`/`setup.ps1` never leaves the database publicly reachable. The other services (Storage, Search, Key Vault, Cosmos, Foundry) stay private the whole time; the Function App reaches them over its own VNet integration, no toggling needed. Calling `setup-database.ps1` directly still requires `psql` and either `Enabled` or VNet access, same as before.
- The PostgreSQL admin password is generated inside Bicep from `newGuid()` on **every** `azd up` and stored in Key Vault as `postgres-admin-password`. Pin it with `azd env set POSTGRES_ADMIN_PASSWORD '<value>'` if a stable value is needed.
- If the Foundry `Agents` capability host fails to deploy in a region, `azd env set USE_CUSTOM_FOUNDRY_STORAGE false` falls back to Microsoft-managed thread storage.
