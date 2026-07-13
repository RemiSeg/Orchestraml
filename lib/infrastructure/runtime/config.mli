(** Validated coordinator environment configuration. *)
type t = { database_url : Uri.t; listen_address : string; port : int;
  db_pool_size : int; migrations_dir : string; log_level : string;
  scheduler_interval : float; retry_interval : float; maintenance_interval : float;
  worker_suspect_after : int; worker_offline_after : int;
  assignment_ack_timeout : int; execution_report_grace : int;
  heartbeat_recovery_grace : int; maintenance_batch_size : int;
  startup_reconciliation_max_passes : int; log_follow_poll : float }
val load : unit -> (t, string list) result
