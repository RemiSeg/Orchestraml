type control
val create_control : unit -> control
val stop : control -> unit
val run : control:control -> sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> process_mgr:_ Eio.Process.mgr ->
  config:Runtime.Config.t -> worker_id:Orchestraml_domain.Identifiers.Worker_id.t ->
  client:Client.Coordinator.t -> unit
