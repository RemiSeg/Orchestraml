CREATE TABLE attempt_recovery_state (
  attempt_id uuid PRIMARY KEY REFERENCES job_attempts(id) ON DELETE CASCADE,
  missing_since_at timestamptz NOT NULL
);
ALTER TABLE job_attempts ADD COLUMN assignment_polled_at timestamptz;
ALTER TABLE job_attempts ADD CONSTRAINT job_attempts_assignment_polled_chronology
  CHECK (assignment_polled_at IS NULL OR assignment_polled_at >= assigned_at);

CREATE INDEX job_attempts_unacknowledged_idx
  ON job_attempts(assigned_at, id)
  WHERE status = 'assigned' AND acknowledged_at IS NULL;

CREATE INDEX job_attempts_running_started_idx
  ON job_attempts(started_at, id)
  WHERE status = 'running';

CREATE INDEX workers_last_heartbeat_idx ON workers(last_heartbeat, id);
CREATE INDEX jobs_retry_ready_idx ON jobs(next_retry_at, id)
  WHERE status = 'retry_waiting';
