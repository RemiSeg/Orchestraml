CREATE TABLE worker_heartbeat_reports (
  worker_id uuid PRIMARY KEY REFERENCES workers(id) ON DELETE RESTRICT,
  reported_at timestamptz NOT NULL,
  available_slots integer NOT NULL CHECK (available_slots >= 0),
  active_attempt_ids uuid[] NOT NULL DEFAULT '{}'
);
