-- Enterprise RAG schema with pgvector and native Row-Level Security.
-- Run as the PostgreSQL Entra administrator against the ragdb database, e.g.:
--   psql "host=<server>.postgres.database.azure.com dbname=ragdb user=<entra-admin-upn> sslmode=require" -f db/schema.sql
-- Vector dimension must match the App Configuration key Rag:EmbeddingDimensions.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------------------------------------------------------------------------
-- Application role: the function app's managed identity logs in via Entra as
-- this role name (created with pgaadauth_create_principal, see scripts/setup-database.ps1).
-- It must NOT be a superuser / owner so that RLS is enforced.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    owner_oid   text        NOT NULL,               -- Entra object id of the uploader
    filename    text        NOT NULL,
    blob_url    text        NOT NULL,
    content_type text,
    -- Async ingestion state, updated by the blob-trigger processor.
    status        text        NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    error_message text,
    chunk_count   int         NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Optional sharing: a document is visible to members of these Entra groups.
CREATE TABLE IF NOT EXISTS document_acl (
    document_id uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    group_oid   text NOT NULL,                      -- Entra group object id
    PRIMARY KEY (document_id, group_oid)
);

CREATE TABLE IF NOT EXISTS chunks (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index int  NOT NULL,
    content     text NOT NULL,
    citation    jsonb NOT NULL DEFAULT '{}'::jsonb, -- { filename, page, chunkIndex, blobUrl }
    embedding   vector(1536) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);
CREATE INDEX IF NOT EXISTS idx_chunks_embedding ON chunks
    USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_document_acl_group ON document_acl(group_oid);

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- The app sets, per transaction:
--   SET LOCAL app.user_oid = '<caller entra object id>';
--   SET LOCAL app.groups   = '<comma separated entra group object ids>';
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_current_user_oid() RETURNS text
    LANGUAGE sql STABLE AS $$ SELECT current_setting('app.user_oid', true) $$;

CREATE OR REPLACE FUNCTION app_current_groups() RETURNS text[]
    LANGUAGE sql STABLE AS
    $$ SELECT string_to_array(coalesce(current_setting('app.groups', true), ''), ',') $$;

ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
ALTER TABLE chunks ENABLE ROW LEVEL SECURITY;
ALTER TABLE chunks FORCE ROW LEVEL SECURITY;
ALTER TABLE document_acl ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_acl FORCE ROW LEVEL SECURITY;

-- Documents: owner or member of a group in the ACL.
DROP POLICY IF EXISTS documents_select ON documents;
CREATE POLICY documents_select ON documents FOR SELECT
    USING (
        owner_oid = app_current_user_oid()
        OR EXISTS (
            SELECT 1 FROM document_acl a
            WHERE a.document_id = documents.id
              AND a.group_oid = ANY (app_current_groups())
        )
    );

DROP POLICY IF EXISTS documents_insert ON documents;
CREATE POLICY documents_insert ON documents FOR INSERT
    WITH CHECK (owner_oid = app_current_user_oid());

DROP POLICY IF EXISTS documents_delete ON documents;
CREATE POLICY documents_delete ON documents FOR DELETE
    USING (owner_oid = app_current_user_oid());

-- The blob-trigger processor updates ingestion status while running under the
-- document owner's identity (recovered from blob metadata), so RLS still applies.
DROP POLICY IF EXISTS documents_update ON documents;
CREATE POLICY documents_update ON documents FOR UPDATE
    USING (owner_oid = app_current_user_oid())
    WITH CHECK (owner_oid = app_current_user_oid());

-- ACL entries: only the owner manages sharing; visible rows follow the document.
DROP POLICY IF EXISTS document_acl_all ON document_acl;
CREATE POLICY document_acl_all ON document_acl FOR ALL
    USING (EXISTS (
        SELECT 1 FROM documents d
        WHERE d.id = document_acl.document_id
          AND d.owner_oid = app_current_user_oid()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM documents d
        WHERE d.id = document_acl.document_id
          AND d.owner_oid = app_current_user_oid()
    ));

-- Chunks: visible when the parent document is visible.
DROP POLICY IF EXISTS chunks_select ON chunks;
CREATE POLICY chunks_select ON chunks FOR SELECT
    USING (EXISTS (
        SELECT 1 FROM documents d
        WHERE d.id = chunks.document_id
          AND (
              d.owner_oid = app_current_user_oid()
              OR EXISTS (
                  SELECT 1 FROM document_acl a
                  WHERE a.document_id = d.id
                    AND a.group_oid = ANY (app_current_groups())
              )
          )
    ));

DROP POLICY IF EXISTS chunks_insert ON chunks;
CREATE POLICY chunks_insert ON chunks FOR INSERT
    WITH CHECK (EXISTS (
        SELECT 1 FROM documents d
        WHERE d.id = chunks.document_id
          AND d.owner_oid = app_current_user_oid()
    ));

DROP POLICY IF EXISTS chunks_delete ON chunks;
CREATE POLICY chunks_delete ON chunks FOR DELETE
    USING (EXISTS (
        SELECT 1 FROM documents d
        WHERE d.id = chunks.document_id
          AND d.owner_oid = app_current_user_oid()
    ));

-- ---------------------------------------------------------------------------
-- Grants for the application role (created by scripts/setup-database.ps1 with
-- the function app's managed identity name). Replace :app_role when running manually.
-- ---------------------------------------------------------------------------
-- GRANT USAGE ON SCHEMA public TO "<function-app-name>";
-- GRANT SELECT, INSERT, UPDATE, DELETE ON documents, document_acl, chunks TO "<function-app-name>";
