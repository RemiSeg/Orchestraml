open Orchestraml_domain.Foundation
type t = { mutable current : Timestamp.t }
let create initial = { current = initial }
let port value : Orchestraml_application.Ports.Clock.t = { now = fun () -> value.current }
let advance value ~seconds = match Timestamp.add_seconds value.current seconds with
  | None -> Error "timestamp overflow"
  | Some timestamp -> value.current <- timestamp; Ok ()
