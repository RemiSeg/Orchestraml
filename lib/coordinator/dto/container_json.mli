val decode : attempt_id:Orchestraml_domain.Identifiers.Attempt_id.t -> Yojson.Safe.t ->
  (Orchestraml_domain.Identifiers.Worker_id.t *
   Orchestraml_application.Ports.Persistence.container_metadata, string list) result
val encode : Orchestraml_application.Ports.Persistence.container_metadata -> Yojson.Safe.t
