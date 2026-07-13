(** Cohttp-eio adapter for the transport-independent router. *)
val run : sw:Eio.Switch.t -> net:_ Eio.Net.t -> clock:_ Eio.Time.clock ->
  follow_interval:float -> listen_address:string -> port:int ->
  Api.Router.t -> unit
