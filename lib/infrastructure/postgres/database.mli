(** Caqti Eio connection-pool construction and health checks. *)
type t = (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t
val connect : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> Uri.t ->
  (t, string) result
val health : t -> (unit, string) result
