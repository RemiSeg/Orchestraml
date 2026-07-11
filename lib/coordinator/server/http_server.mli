(** Cohttp-eio adapter for the transport-independent router. *)
val run : sw:Eio.Switch.t -> net:_ Eio.Net.t -> listen_address:string -> port:int ->
  Api.Router.t -> unit
