open Orchestraml_domain.Identifiers
type t = {
  next_job_id : unit -> Job_id.t;
  next_attempt_id : unit -> Attempt_id.t;
  next_worker_id : unit -> Worker_id.t;
}
