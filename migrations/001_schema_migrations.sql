CREATE TABLE IF NOT EXISTS schema_migrations (
  version integer PRIMARY KEY CHECK (version > 0),
  filename text NOT NULL UNIQUE,
  checksum text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
