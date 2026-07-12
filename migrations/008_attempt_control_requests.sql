CREATE TABLE attempt_control_requests (
  attempt_id uuid PRIMARY KEY REFERENCES job_attempts(id) ON DELETE RESTRICT,
  worker_id uuid NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('cancel', 'execution_timeout')),
  requested_at timestamptz NOT NULL,
  delivered_at timestamptz,
  completed_at timestamptz,
  CHECK (delivered_at IS NULL OR delivered_at >= requested_at),
  CHECK (completed_at IS NULL OR completed_at >= requested_at),
  CHECK (completed_at IS NULL OR delivered_at IS NOT NULL)
);

CREATE INDEX attempt_control_requests_worker_pending_idx
  ON attempt_control_requests(worker_id, requested_at)
  WHERE completed_at IS NULL;
