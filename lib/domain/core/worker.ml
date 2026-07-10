open Foundation
open Identifiers
open Shared

type t = {
  id : Worker_id.t; name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; active_jobs : int;
  total_resources : Resources.t; reserved_resources : Resources.t;
  available_resources : Resources.t; last_heartbeat : Timestamp.t;
}
let create ~id ~name ~labels ~max_concurrency ~active_jobs ~total_resources ~reserved_resources ~last_heartbeat =
  let name = String.trim name in
  if String.length name = 0 then Error (Validation_error.make ~field:"worker_name" "must not be empty")
  else if active_jobs < 0 then Error (Validation_error.make ~field:"active_jobs" "must be non-negative")
  else if active_jobs > Scalar.Concurrency.value max_concurrency then
    Error (Validation_error.make ~field:"active_jobs" "cannot exceed maximum concurrency")
  else match Resources.subtract ~total:total_resources ~reserved:reserved_resources with
    | Error error -> Error error
    | Ok available_resources -> Ok { id; name; labels; max_concurrency; active_jobs;
        total_resources; reserved_resources; available_resources; last_heartbeat }
let id value = value.id
let name value = value.name
let labels value = value.labels
let max_concurrency value = value.max_concurrency
let active_jobs value = value.active_jobs
let total_resources value = value.total_resources
let reserved_resources value = value.reserved_resources
let available_resources value = value.available_resources
let last_heartbeat value = value.last_heartbeat
let free_slots value = Scalar.Concurrency.value value.max_concurrency - value.active_jobs
