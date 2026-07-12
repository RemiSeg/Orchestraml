ALTER TABLE job_attempts ADD COLUMN acknowledged_at timestamptz;

UPDATE job_attempts
SET acknowledged_at = COALESCE(started_at, assigned_at),
    snapshot = jsonb_set(snapshot, '{acknowledged_at}',
      to_jsonb(COALESCE(started_at, assigned_at)::text), true)
WHERE status <> 'assigned' OR started_at IS NOT NULL;

ALTER TABLE job_attempts ADD CONSTRAINT attempt_acknowledgement_order
  CHECK (acknowledged_at IS NULL OR acknowledged_at >= assigned_at);
ALTER TABLE job_attempts ADD CONSTRAINT attempt_start_requires_acknowledgement
  CHECK (started_at IS NULL OR acknowledged_at IS NOT NULL);
