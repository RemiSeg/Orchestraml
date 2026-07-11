(** Transactional in-memory implementation of application persistence ports. *)
val create : unit -> Ports.Persistence.t
