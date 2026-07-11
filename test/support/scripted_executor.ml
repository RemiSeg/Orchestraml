open Orchestraml_domain.Shared
type outcome = Succeeded of int | Failed of Failure.t | Timed_out | Lost of string | Cancelled
type t = { mutable outcomes : outcome list }
let create outcomes = { outcomes }
let next value = match value.outcomes with
  | [] -> Error "scripted executor has no remaining outcome"
  | outcome :: rest -> value.outcomes <- rest; Ok outcome
