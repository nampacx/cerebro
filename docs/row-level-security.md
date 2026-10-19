# Row-level security: how Cerebro actually isolates tenants

This is the one mechanism the rest of the README keeps pointing back to. Everything else — Entra
sign-in, the chat agent, the ingestion pipeline — exists to get a validated user identity in front
of PostgreSQL and then get out of the way. This document explains what problem that solves, how it's
wired end to end, and walks through the demo that proves it: **one user uploads a document, a second
user never sees it — not in the document list, not in chat citations, not in retrieval — without a
single line of "if user can see this" in application code.**

## The problem this solves

Multi-tenant RAG systems usually enforce access control in application code: a query fetches rows,
then a filter (or a second query) decides which of those rows the caller is allowed to see. That
works, but it has one structural weakness: **every new code path has to remember to do it.** A new
API route, a new background job, a refactored query, an LLM tool call added in a hurry — each one is
a fresh opportunity to forget the check, and the failure mode is silent: the wrong rows just flow
through, and nothing looks wrong until someone notices they can read another tenant's documents.

Cerebro moves that check out of application code and into PostgreSQL itself, using **native
row-level security (RLS)**. The database enforces who can see which rows, for every single query
that touches the `documents`, `chunks`, `document_acl` or `conversations` tables — including vector
similarity search. There is no parallel permission check anywhere in the C# code, because the
database refuses to return a row the caller isn't entitled to **regardless of how the query was
written**. A query that forgets to set the caller's identity doesn't leak data — it gets zero rows
back, same as if the data didn't exist.

## How it's wired

Three pieces make this work together:

### 1. A non-privileged database connection

[`PgVectorStore`](../src/RagApp.Functions/Services/PgVectorStore.cs) connects to PostgreSQL as the
function app's own managed identity — a plain Entra role with no special privileges, not the
Postgres admin. [`db/schema.sql`](../db/schema.sql) applies `FORCE ROW LEVEL SECURITY` to every
table, which matters specifically *because* the connection isn't a superuser or table owner —
`FORCE` is what makes RLS apply even to the role that would otherwise bypass it.

### 2. Per-request identity, set inside the transaction

Every method on `PgVectorStore` opens a transaction and immediately calls `SetUserContextAsync`,
which runs:

```sql
SELECT set_config('app.user_oid', @oid, true), set_config('app.groups', @groups, true)
```

`true` here means `SET LOCAL` semantics — the setting only exists for the current transaction and
evaporates the moment it commits or rolls back. There's no session state to leak between requests,
no connection-pool contamination, no risk that one caller's identity lingers and gets attached to
someone else's query on a pooled connection. `@oid` and `@groups` come from the validated JWT (see
[`EntraTokenValidator`](../src/RagApp.Functions/Auth/EntraTokenValidator.cs)) — never from anything
the caller can set directly, since they travel through `SetUserContextAsync`'s SQL parameters, not
string-concatenated input.

### 3. Policies that read that identity back

`db/schema.sql` defines two small SQL functions:

```sql
CREATE FUNCTION app_current_user_oid() RETURNS text
    LANGUAGE sql STABLE AS $$ SELECT current_setting('app.user_oid', true) $$;

CREATE FUNCTION app_current_groups() RETURNS text[]
    LANGUAGE sql STABLE AS
    $$ SELECT string_to_array(coalesce(current_setting('app.groups', true), ''), ',') $$;
```

...and every RLS policy is built from them. For documents:

```sql
CREATE POLICY documents_select ON documents FOR SELECT
    USING (
        owner_oid = app_current_user_oid()
        OR EXISTS (
            SELECT 1 FROM document_acl a
            WHERE a.document_id = documents.id
              AND a.group_oid = ANY (app_current_groups())
        )
    );
```

A row is visible if the caller is the owner, **or** the caller belongs to an Entra group the
document was explicitly shared with via `document_acl`. `chunks_select` applies the identical logic
one level down — a chunk is visible exactly when its parent document is — so **vector similarity
search is filtered by the same policy**, with no separate relevance-then-permission-filter step in
`RagAgentService` or anywhere else. The query planner applies the `USING` clause as part of the
index scan itself.

This is why "new queries go in `PgVectorStore` and take a `UserContext`" is a hard rule in
[`CLAUDE.md`](../CLAUDE.md): a connection opened anywhere else, or a query that skips
`SetUserContextAsync`, doesn't bypass RLS and leak data — PostgreSQL still enforces `FORCE ROW LEVEL
SECURITY` regardless — it just means `app.user_oid` is unset, every `USING` clause evaluates to
false, and the query silently returns nothing. Safe by default, but worth knowing: a forgotten
`SetUserContextAsync` call looks like "no results" or "empty document list," not like an exception.

## The demo: Alice uploads, Bob doesn't see it

This is the one-sentence version of everything above, made concrete. You need two Entra ID accounts
in the tenant the app is registered in — they don't need to share a group, and for this demo
shouldn't.

**1. Sign in as Alice and upload a document.**

Through the web app (easiest): sign in, go to the upload view, and upload any PDF — say,
`q3-roadmap.pdf`. Once ingestion finishes, Alice's document list shows it with `status: completed`.

Or directly against the API — grab Alice's access token from the browser's network tab after she
signs in (any authenticated call to `/api/documents` shows the `Authorization: Bearer ...` header
to copy), then:

```bash
curl -X POST https://<function-app>.azurewebsites.net/api/documents \
  -H "Authorization: Bearer <alice-token>" \
  -F "file=@q3-roadmap.pdf"
```

**2. As Alice, confirm it's there.**

```bash
curl https://<function-app>.azurewebsites.net/api/documents \
  -H "Authorization: Bearer <alice-token>"
```

Returns the document, `chunk_count` populated, `status: "completed"`.

**3. As Alice, ask the chat agent about it.**

```bash
curl -X POST https://<function-app>.azurewebsites.net/api/chat \
  -H "Authorization: Bearer <alice-token>" -H "Content-Type: application/json" \
  -d '{"message": "What does the Q3 roadmap say about the Q4 launch date?"}'
```

The agent calls `search_documents`, finds the relevant chunk, and answers with a citation back to
`q3-roadmap.pdf`.

**4. Sign in as Bob — someone in the same tenant, not in any group the document was shared with —
and repeat steps 2 and 3.**

```bash
curl https://<function-app>.azurewebsites.net/api/documents \
  -H "Authorization: Bearer <bob-token>"
# []  — Alice's document isn't in the list. Not hidden by the UI: it was never in the response.

curl -X POST https://<function-app>.azurewebsites.net/api/chat \
  -H "Authorization: Bearer <bob-token>" -H "Content-Type: application/json" \
  -d '{"message": "What does the Q3 roadmap say about the Q4 launch date?"}'
# The agent's search_documents call returns "No matching documents found." — the agent
# tells Bob it couldn't find anything relevant, because as far as his query was concerned,
# nothing relevant exists.
```

Same Postgres instance, same `chunks` table with Alice's embeddings sitting right there, same SQL
query shape, same deployed code — the only thing that changed between steps 2–3 and step 4 is whose
JWT was on the request. That's `app.user_oid` flipping from Alice's object id to Bob's inside
`SetUserContextAsync`, and `documents_select` / `chunks_select` silently filtering Alice's rows out
of every result set Bob's queries touch. Nothing in `DocumentsFunction`, `ChatFunction` or
`RagAgentService` branches on "whose document is this" — they don't have to.

**5. Now share it, and watch Bob gain access without any code changing.**

Re-upload (or have Alice share the existing one, if the UI supports it) with Bob's Entra group id in
`groupIds`:

```bash
curl -X POST https://<function-app>.azurewebsites.net/api/documents \
  -H "Authorization: Bearer <alice-token>" \
  -F "file=@q3-roadmap.pdf" -F "groupIds=<bobs-entra-group-object-id>"
```

Repeat step 4 as Bob: the document now appears in his list, and the chat agent can cite it. The
`document_acl` row is the only thing that changed — `documents_select`'s `OR EXISTS (... a.group_oid
= ANY (app_current_groups()))` branch just started matching.

## What RLS does *not* cover

Downloading the original file (`GET /api/documents/{id}/download`) is deliberately **stricter** than
the RLS visibility above: it checks `owner_oid` directly in application code rather than relying on
`documents_select`, so group-shared documents can be searched and cited in chat but not downloaded
by anyone except the owner. This is the one place the codebase layers an explicit check on top of
RLS rather than relying on it alone — see the comment on
[`PgVectorStore.GetDocumentBlobInfoAsync`](../src/RagApp.Functions/Services/PgVectorStore.cs) for why.

Network isolation is also explicitly **not** part of this threat model: every backing service
deploys with public network access enabled, and RLS — not a VNet — is the access-control boundary.
See the "Security notes" section near the bottom of the main [README](../README.md) for the full
reasoning.
