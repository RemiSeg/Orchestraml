CREATE TABLE attempt_logs (
  attempt_id uuid NOT NULL REFERENCES job_attempts(id) ON DELETE RESTRICT,
  sequence_number integer NOT NULL CHECK (sequence_number > 0),
  stream text NOT NULL CHECK (stream IN ('stdout','stderr')),
  observed_at timestamptz NOT NULL,
  payload bytea NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(attempt_id, sequence_number)
);
CREATE INDEX attempt_logs_ordered_idx ON attempt_logs(attempt_id, sequence_number);
