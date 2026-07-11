(** Stable JSON snapshots used to restore private domain entities from rows. *)
open Orchestraml_domain.Core
val job_to_string : Job.t -> string
val job_of_string : string -> (Job.t, string) result
val attempt_to_string : Attempt.t -> string
val attempt_of_string : string -> (Attempt.t, string) result
val worker_to_string : Worker.t -> string
val worker_of_string : string -> (Worker.t, string) result
