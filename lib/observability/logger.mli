(** JSON-lines operational logging. Values must never contain secrets or job output. *)
type level = Debug | Info | Warning | Error

val to_json : level:level -> component:string -> event:string -> message:string ->
  ?job_id:string -> ?attempt_id:string -> ?worker_id:string -> unit -> Yojson.Safe.t
val emit : level:level -> component:string -> event:string -> message:string ->
  ?job_id:string -> ?attempt_id:string -> ?worker_id:string -> unit -> unit
