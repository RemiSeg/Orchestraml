(** Validated coordinator environment configuration. *)
type t = { database_url : Uri.t; listen_address : string; port : int;
  db_pool_size : int; migrations_dir : string; log_level : string }
val load : unit -> (t, string list) result
