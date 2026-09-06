# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An enterprise RAG platform on Azure: documents are chunked and embedded into PostgreSQL `pgvector`, and **every** query is filtered by native PostgreSQL row-level security keyed on the calling user's Entra ID `oid`/`groups` claims. Deployed with `azd` as two services declared in [azure.yaml](azure.yaml): `api` (Azure Functions, .NET 10 isolated) and `web` (React + Vite on Static Web Apps).

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
# Full provision + deploy (creates app registration, azd env, runs azd up)
./scripts/setup.ps1 -EnvironmentName rag-dev -PublicNetworkAccess Enabled -InitializeDatabase

# Redeploy one service after code changes
azd deploy api
azd deploy web

# Apply db/schema.sql and create the managed-identity role (needs psql + network access to the server)
./scripts/setup-database.ps1 -ServerName <psql-server-name> -FunctionAppName <function-app-name>
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

**Ingestion is split across two processes** and the ingestion context travels through blob metadata:

1. [Services/DocumentUploadService.cs](src/RagApp.Functions/Services/DocumentUploadService.cs) — writes the `pending` row *before* uploading the blob (so the row exists when the trigger fires), stamps `ownerOid` / `documentId` / `groupIds` / `originalFilename` metadata (keys are `const` on that class), returns `202`.
2. [Functions/ProcessDocumentFunction.cs](src/RagApp.Functions/Functions/ProcessDocumentFunction.cs) → [Services/DocumentProcessingService.cs](src/RagApp.Functions/Services/DocumentProcessingService.cs) — the blob trigger runs under the *app* identity but reconstructs `new UserContext(ownerOid, [], null)` from that metadata, so writes still pass owner-scoped RLS policies. Status transitions `pending → processing → completed|failed`; `AddChunksAsync` deletes existing chunks first, making reprocessing idempotent.

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
- Default `PUBLIC_NETWORK_ACCESS=Disabled` puts every backing service behind private endpoints; `setup-database.ps1` and any local `psql` need `Enabled` or VNet access.
- The PostgreSQL admin password is generated inside Bicep from `newGuid()` on **every** `azd up` and stored in Key Vault as `postgres-admin-password`. Pin it with `azd env set POSTGRES_ADMIN_PASSWORD '<value>'` if a stable value is needed.
- If the Foundry `Agents` capability host fails to deploy in a region, `azd env set USE_CUSTOM_FOUNDRY_STORAGE false` falls back to Microsoft-managed thread storage.
