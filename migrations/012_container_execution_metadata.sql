CREATE TABLE container_execution_metadata (
  attempt_id uuid PRIMARY KEY REFERENCES job_attempts(id) ON DELETE RESTRICT,
  worker_id uuid NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  container_id text NOT NULL,
  container_name text NOT NULL UNIQUE,
  image_reference text NOT NULL,
  created_at timestamptz NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  removed_at timestamptz,
  cleanup_outcome text NOT NULL CHECK (cleanup_outcome IN ('pending','removed','failed')),
  CHECK (started_at IS NULL OR started_at >= created_at),
  CHECK (finished_at IS NULL OR (started_at IS NOT NULL AND finished_at >= started_at)),
  CHECK (removed_at IS NULL OR removed_at >= created_at),
  CHECK ((cleanup_outcome = 'removed') = (removed_at IS NOT NULL))
);
CREATE INDEX container_cleanup_idx ON container_execution_metadata(cleanup_outcome, created_at)
  WHERE cleanup_outcome <> 'removed';
