open Orchestraml_domain.Foundation
module Persistence = Ports.Persistence

type t = { persistence : Persistence.t; clock : Ports.Clock.t;
  suspect_after_seconds : int; offline_after_seconds : int }
type error = Persistence_error of Persistence.error | Invalid_clock

let create ~persistence ~clock ~suspect_after_seconds ~offline_after_seconds =
  { persistence; clock; suspect_after_seconds; offline_after_seconds }

let snapshot service =
  let now = service.clock.now () in
  match Timestamp.add_seconds now (-service.suspect_after_seconds),
        Timestamp.add_seconds now (-service.offline_after_seconds) with
  | Some suspect_before, Some offline_before ->
      (match service.persistence.with_transaction (fun repositories ->
         repositories.Persistence.metrics.snapshot ~now ~suspect_before ~offline_before) with
       | Error error -> Error (Persistence_error error)
       | Ok (Error error) -> Error (Persistence_error error)
       | Ok (Ok value) -> Ok value)
  | _ -> Error Invalid_clock
