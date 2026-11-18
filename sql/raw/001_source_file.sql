-- Raw layer: one row per upstream file, payload stored as jsonb, untouched.
--
-- Grain: one row per source file (file_path is the path under data/raw/).
-- "Untouched" means semantically identical JSON: jsonb normalises whitespace
-- and key order, so sha256/byte_size record the exact original bytes for
-- provenance. Nothing downstream may write to this schema.

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.source_file (
    file_path   text        PRIMARY KEY,
    source      text        NOT NULL CHECK (source IN ('statsbomb', 'openfootball')),
    entity      text        NOT NULL CHECK (entity IN ('competitions', 'matches', 'events', 'lineups', 'results')),
    source_ref  text        NOT NULL,           -- upstream git commit the file was fetched at
    sha256      text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    byte_size   integer     NOT NULL CHECK (byte_size > 0),
    payload     jsonb       NOT NULL,
    loaded_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS source_file_source_entity_idx ON raw.source_file (source, entity);

COMMENT ON TABLE raw.source_file IS
  'Grain: one row per upstream JSON file. Payload is the parsed file, unmodified.';

-- Reads a file from the server-side mount (/data/raw), so it must run as a
-- role with pg_read_server_files (the container superuser does).
CREATE OR REPLACE FUNCTION raw.load_file(p_source text, p_entity text, p_path text, p_ref text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    b bytea := pg_read_binary_file('/data/raw/' || p_path);
BEGIN
    INSERT INTO raw.source_file (file_path, source, entity, source_ref, sha256, byte_size, payload)
    VALUES (p_path, p_source, p_entity, p_ref, encode(sha256(b), 'hex'), length(b),
            convert_from(b, 'UTF8')::jsonb)
    ON CONFLICT (file_path) DO UPDATE
       SET source = EXCLUDED.source, entity = EXCLUDED.entity, source_ref = EXCLUDED.source_ref,
           sha256 = EXCLUDED.sha256, byte_size = EXCLUDED.byte_size,
           payload = EXCLUDED.payload, loaded_at = now()
     WHERE raw.source_file.sha256 IS DISTINCT FROM EXCLUDED.sha256
        OR raw.source_file.source_ref IS DISTINCT FROM EXCLUDED.source_ref;
END;
$$;
