open Orchestraml_domain.Foundation
open Orchestraml_domain.Shared
type t = { coordinator_url : Uri.t; identity_file : string; name : string;
  labels : Worker_label.Set.t; max_concurrency : Scalar.Concurrency.t;
  resources : Resources.t; heartbeat_interval : float; poll_interval : float;
  control_poll_interval : float; termination_grace : float; docker_executable_value:string;
  log_batch_bytes_value:int; log_flush_interval_value:float; log_pending_limit_value:int }
let env name default = Sys.getenv_opt name |> Option.value ~default
let load () =
  let errors = ref [] in
  let required name = match Sys.getenv_opt name with
    | Some value when String.trim value <> "" -> value
    | _ -> errors := (name ^ " is required") :: !errors; "" in
  let integer name minimum = match int_of_string_opt (required name) with
    | Some value when value >= minimum -> value
    | _ -> errors := (name ^ " is invalid") :: !errors; minimum in
  let interval name default = match float_of_string_opt (env name default) with
    | Some value when value > 0. -> value
    | _ -> errors := (name ^ " must be positive") :: !errors; 1. in
  let positive_int name default = match int_of_string_opt (env name default) with
    | Some value when value > 0 -> value
    | _ -> errors := (name ^ " must be positive") :: !errors; int_of_string default in
  let labels = env "WORKER_LABELS" "" |> String.split_on_char ',' |> List.filter_map (fun raw ->
    if String.trim raw = "" then None else match Worker_label.create raw with
      | Ok value -> Some value | Error _ -> errors := "WORKER_LABELS is invalid" :: !errors; None)
    |> List.fold_left (fun set value -> Worker_label.Set.add value set) Worker_label.Set.empty in
  let coordinator_url = required "COORDINATOR_URL" |> Uri.of_string in
  if Uri.scheme coordinator_url <> Some "http" then
    errors := "COORDINATOR_URL must use http in Phase 4" :: !errors;
  let log_batch_bytes_value = positive_int "LOG_BATCH_BYTES" "65536" in
  let log_pending_limit_value = positive_int "LOG_PENDING_LIMIT_BYTES" "4194304" in
  if log_batch_bytes_value > log_pending_limit_value then
    errors := "LOG_BATCH_BYTES must not exceed LOG_PENDING_LIMIT_BYTES" :: !errors;
  if log_pending_limit_value > 64 * 1024 * 1024 then
    errors := "LOG_PENDING_LIMIT_BYTES must not exceed 67108864" :: !errors;
  let value = {
    coordinator_url;
    identity_file = env "WORKER_ID_FILE" "/var/lib/orchestraml/worker-id";
    name = required "WORKER_NAME"; labels;
    max_concurrency = Scalar.Concurrency.create (integer "WORKER_MAX_CONCURRENCY" 1) |> Result.get_ok;
    resources = Resources.create
      ~cpu:(Scalar.Cpu_millicores.create (integer "WORKER_CPU_MILLICORES" 0) |> Result.get_ok)
      ~memory:(Scalar.Memory_mib.create (integer "WORKER_MEMORY_MIB" 0) |> Result.get_ok);
    heartbeat_interval = interval "HEARTBEAT_INTERVAL_SECONDS" "10";
    poll_interval = interval "POLL_INTERVAL_SECONDS" "2";
    control_poll_interval = interval "CONTROL_POLL_INTERVAL_SECONDS" "1";
    termination_grace = interval "TERMINATION_GRACE_SECONDS" "5";
    docker_executable_value = env "DOCKER_EXECUTABLE" "docker";
    log_batch_bytes_value; log_flush_interval_value = interval "LOG_FLUSH_INTERVAL_SECONDS" "0.5";
    log_pending_limit_value } in
  match List.rev !errors with [] -> Ok value | errors -> Error errors
let docker_executable value = value.docker_executable_value
let log_batch_bytes value = value.log_batch_bytes_value
let log_flush_interval value = value.log_flush_interval_value
let log_pending_limit value = value.log_pending_limit_value
