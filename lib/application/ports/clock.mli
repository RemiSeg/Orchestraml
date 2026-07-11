(** Time source injected into application services. *)
open Orchestraml_domain.Foundation
type t = { now : unit -> Timestamp.t }
