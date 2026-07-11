CREATE TABLE workers (
  id uuid PRIMARY KEY,
  name text NOT NULL CHECK (length(name) > 0),
  snapshot jsonb NOT NULL,
  max_concurrency integer NOT NULL CHECK (max_concurrency > 0),
  active_jobs integer NOT NULL CHECK (active_jobs >= 0 AND active_jobs <= max_concurrency),
  total_cpu_millicores integer NOT NULL CHECK (total_cpu_millicores >= 0),
  reserved_cpu_millicores integer NOT NULL CHECK (reserved_cpu_millicores >= 0 AND reserved_cpu_millicores <= total_cpu_millicores),
  total_memory_mib integer NOT NULL CHECK (total_memory_mib >= 0),
  reserved_memory_mib integer NOT NULL CHECK (reserved_memory_mib >= 0 AND reserved_memory_mib <= total_memory_mib),
  last_heartbeat timestamptz NOT NULL
);

CREATE TABLE worker_labels (
  worker_id uuid NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  label text NOT NULL,
  PRIMARY KEY (worker_id, label)
);
