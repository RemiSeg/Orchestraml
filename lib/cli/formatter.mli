(** Stable human and machine-readable CLI output. *)
val json : Yojson.Safe.t -> string
val job : Yojson.Safe.t -> string
val jobs : Yojson.Safe.t -> string
val attempts : Yojson.Safe.t -> string
val events : Yojson.Safe.t -> string
val workers : Yojson.Safe.t -> string
val worker : Yojson.Safe.t -> string
val log_entry : attempt_id:string -> Yojson.Safe.t -> string
