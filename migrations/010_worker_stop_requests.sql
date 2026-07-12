CREATE TABLE worker_stop_requests (
  worker_id uuid NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  reported_attempt_id uuid NOT NULL,
  requested_at timestamptz NOT NULL,
  delivered_at timestamptz,
  completed_at timestamptz,
  PRIMARY KEY(worker_id, reported_attempt_id),
  CHECK (delivered_at IS NULL OR delivered_at >= requested_at),
  CHECK (completed_at IS NULL OR completed_at >= requested_at),
  CHECK (completed_at IS NULL OR delivered_at IS NOT NULL)
);
CREATE INDEX worker_stop_requests_pending_idx
  ON worker_stop_requests(worker_id, requested_at, reported_attempt_id)
  WHERE completed_at IS NULL;
