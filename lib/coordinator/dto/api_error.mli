(** Stable structured API error responses. *)
val json : code:string -> message:string -> ?fields:(string * string) list -> unit -> Yojson.Safe.t
