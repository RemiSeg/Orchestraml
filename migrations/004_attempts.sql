CREATE TABLE job_attempts (
  id uuid PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
  worker_id uuid NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  snapshot jsonb NOT NULL,
  attempt_number integer NOT NULL CHECK (attempt_number > 0),
  status text NOT NULL CHECK (status IN ('assigned','running','succeeded','failed','timed_out','lost','cancelled')),
  assigned_at timestamptz NOT NULL,
  started_at timestamptz,
  finished_at timestamptz,
  outcome_kind text,
  exit_code integer,
  failure_kind text,
  failure_message text,
  lost_reason text,
  UNIQUE (job_id, attempt_number),
  CHECK (started_at IS NULL OR started_at >= assigned_at),
  CHECK (finished_at IS NULL OR finished_at >= COALESCE(started_at, assigned_at))
);

CREATE UNIQUE INDEX one_active_attempt_per_job
  ON job_attempts(job_id) WHERE status IN ('assigned','running');
