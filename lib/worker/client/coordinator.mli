open Orchestraml_domain
open Foundation
open Identifiers
open Shared
type assignment = { job_id : Job_id.t; attempt_id : Attempt_id.t;
  attempt_number : Scalar.Attempt_number.t; execution : Execution_spec.t;
  timeout : Scalar.Timeout_seconds.t; resources : Resources.t }
type registration = { worker_id : Worker_id.t; name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; resources : Resources.t }
type result_report = Succeeded of int | Failed of Failure.t | Timed_out | Cancelled
type control = Cancel of Attempt_id.t | Execution_timeout of Attempt_id.t | Stop_unknown of Attempt_id.t
type cleanup = Pending | Removed | Cleanup_failed
type container_metadata = { attempt_id:Attempt_id.t; worker_id:Worker_id.t;
  container_id:string; container_name:string; image_reference:string;
  created_at:Timestamp.t; started_at:Timestamp.t option; finished_at:Timestamp.t option;
  removed_at:Timestamp.t option; cleanup:cleanup }
type error = Transport of string | Protocol of int * string | Invalid_response of string
type t
val create : client:Cohttp_eio.Client.t -> base_uri:Uri.t -> clock:_ Eio.Time.clock ->
  request_timeout:float -> t
val register : sw:Eio.Switch.t -> t -> registration -> (unit, error) result
val heartbeat : sw:Eio.Switch.t -> t -> worker_id:Worker_id.t -> available_slots:int ->
  active_attempt_ids:Attempt_id.t list -> (unit, error) result
val poll : sw:Eio.Switch.t -> t -> Worker_id.t -> (assignment option, error) result
val poll_controls : sw:Eio.Switch.t -> t -> Worker_id.t -> (control list, error) result
val confirm_stopped : sw:Eio.Switch.t -> t -> worker_id:Worker_id.t -> Attempt_id.t -> (unit, error) result
val acknowledge : sw:Eio.Switch.t -> t -> Attempt_id.t -> (unit, error) result
val started : sw:Eio.Switch.t -> t -> Attempt_id.t -> (unit, error) result
val report : sw:Eio.Switch.t -> t -> Attempt_id.t -> result_report -> (unit, error) result
val upload_logs : sw:Eio.Switch.t -> t -> worker_id:Worker_id.t -> attempt_id:Attempt_id.t ->
  Log_entry.t list -> (int, error) result
val record_container : sw:Eio.Switch.t -> t -> container_metadata -> (unit,error) result
val find_container : sw:Eio.Switch.t -> t -> Attempt_id.t -> (container_metadata option,error) result
val pp_error : Format.formatter -> error -> unit
val retryable : error -> bool
