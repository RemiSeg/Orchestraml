CREATE TABLE transition_events (
  id bigserial PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES jobs(id) ON DELETE RESTRICT,
  attempt_id uuid REFERENCES job_attempts(id) ON DELETE RESTRICT,
  entity_kind text NOT NULL CHECK (entity_kind IN ('job','attempt')),
  snapshot jsonb NOT NULL,
  from_status text NOT NULL,
  to_status text NOT NULL,
  occurred_at timestamptz NOT NULL,
  reason text,
  CHECK ((entity_kind = 'job' AND attempt_id IS NULL) OR
         (entity_kind = 'attempt' AND attempt_id IS NOT NULL))
);

CREATE INDEX transition_events_job_order_idx ON transition_events(job_id, id);
