type t = { database_url : Uri.t; listen_address : string; port : int;
  db_pool_size : int; migrations_dir : string; log_level : string;
  scheduler_interval : float; retry_interval : float; maintenance_interval : float;
  worker_suspect_after : int; worker_offline_after : int;
  assignment_ack_timeout : int; execution_report_grace : int;
  heartbeat_recovery_grace : int; maintenance_batch_size : int;
  startup_reconciliation_max_passes : int }
let env name default = match Sys.getenv_opt name with Some value -> value | None -> default
let int_env errors name default ~min ~max =
  match int_of_string_opt (env name (string_of_int default)) with
  | Some value when value >= min && value <= max -> value
  | _ -> errors := (Printf.sprintf "%s must be between %d and %d" name min max) :: !errors; default
let float_env errors name default = match float_of_string_opt (env name (string_of_float default)) with
  | Some value when value > 0. -> value
  | _ -> errors := (name ^ " must be positive") :: !errors; default
let load () =
  let errors = ref [] in
  let database_url = match Sys.getenv_opt "DATABASE_URL" with
    | Some value when String.trim value <> "" -> Uri.of_string value
    | _ -> errors := "DATABASE_URL is required" :: !errors; Uri.empty in
  let port = int_env errors "PORT" 8080 ~min:1 ~max:65535 in
  let db_pool_size = int_env errors "DB_POOL_SIZE" 10 ~min:1 ~max:100 in
  let worker_suspect_after = int_env errors "WORKER_SUSPECT_AFTER_SECONDS" 30 ~min:1 ~max:max_int in
  let worker_offline_after = int_env errors "WORKER_OFFLINE_AFTER_SECONDS" 60 ~min:1 ~max:max_int in
  if worker_suspect_after >= worker_offline_after then
    errors := "WORKER_SUSPECT_AFTER_SECONDS must be lower than WORKER_OFFLINE_AFTER_SECONDS" :: !errors;
  let value = { database_url; listen_address = env "LISTEN_ADDRESS" "127.0.0.1";
    port; db_pool_size; migrations_dir = env "MIGRATIONS_DIR" "migrations";
    log_level = env "LOG_LEVEL" "info";
    scheduler_interval = float_env errors "SCHEDULER_INTERVAL_SECONDS" 1.;
    retry_interval = float_env errors "RETRY_INTERVAL_SECONDS" 1.;
    maintenance_interval = float_env errors "MAINTENANCE_INTERVAL_SECONDS" 5.;
    worker_suspect_after; worker_offline_after;
    assignment_ack_timeout = int_env errors "ASSIGNMENT_ACK_TIMEOUT_SECONDS" 30 ~min:1 ~max:max_int;
    execution_report_grace = int_env errors "EXECUTION_REPORT_GRACE_SECONDS" 10 ~min:1 ~max:max_int;
    heartbeat_recovery_grace = int_env errors "HEARTBEAT_RECOVERY_GRACE_SECONDS" 20 ~min:1 ~max:max_int;
    maintenance_batch_size = int_env errors "MAINTENANCE_BATCH_SIZE" 100 ~min:1 ~max:1000;
    startup_reconciliation_max_passes = int_env errors "STARTUP_RECONCILIATION_MAX_PASSES" 1000 ~min:1 ~max:10000 } in
  match List.rev !errors with [] -> Ok value | errors -> Error errors
