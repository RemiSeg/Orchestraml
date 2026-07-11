CREATE TABLE jobs (
  id uuid PRIMARY KEY,
  name text NOT NULL CHECK (length(name) > 0),
  status text NOT NULL CHECK (status IN ('pending','assigned','running','retry_waiting','cancelling','completed','permanently_failed','cancelled')),
  execution_spec jsonb NOT NULL,
  snapshot jsonb NOT NULL,
  priority integer NOT NULL,
  cpu_millicores integer NOT NULL CHECK (cpu_millicores >= 0),
  memory_mib integer NOT NULL CHECK (memory_mib >= 0),
  timeout_seconds integer NOT NULL CHECK (timeout_seconds > 0),
  max_attempts integer NOT NULL CHECK (max_attempts > 0),
  retry_initial_delay_seconds integer NOT NULL CHECK (retry_initial_delay_seconds > 0),
  retry_multiplier integer NOT NULL CHECK (retry_multiplier > 0),
  retry_maximum_delay_seconds integer NOT NULL CHECK (retry_maximum_delay_seconds >= retry_initial_delay_seconds),
  retry_timeouts boolean NOT NULL,
  attempts_started integer NOT NULL DEFAULT 0 CHECK (attempts_started >= 0),
  next_retry_at timestamptz,
  idempotency_key text UNIQUE,
  idempotency_payload text,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL CHECK (updated_at >= created_at),
  CHECK ((status = 'retry_waiting') = (next_retry_at IS NOT NULL)),
  CHECK ((idempotency_key IS NULL) = (idempotency_payload IS NULL))
);

CREATE TABLE job_required_labels (
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
  label text NOT NULL,
  PRIMARY KEY (job_id, label)
);

CREATE INDEX jobs_pending_order_idx ON jobs (priority DESC, created_at, id) WHERE status = 'pending';
CREATE INDEX jobs_list_order_idx ON jobs (created_at DESC, id DESC);
