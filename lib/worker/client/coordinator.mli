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
val pp_error : Format.formatter -> error -> unit
val retryable : error -> bool
