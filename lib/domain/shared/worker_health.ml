open Foundation

type t = Healthy | Suspect | Offline
type policy = { suspect_after : Scalar.Timeout_seconds.t; offline_after : Scalar.Timeout_seconds.t }
let create ~suspect_after ~offline_after =
  if Scalar.Timeout_seconds.compare suspect_after offline_after >= 0 then
    Error (Validation_error.make ~field:"offline_after" "must be greater than suspect_after")
  else Ok { suspect_after; offline_after }
let classify policy ~now ~last_heartbeat =
  match Timestamp.diff_seconds ~later:now ~earlier:last_heartbeat with
  | None -> Offline
  | Some age when age < 0 -> Healthy
  | Some age when age >= Scalar.Timeout_seconds.value policy.offline_after -> Offline
  | Some age when age >= Scalar.Timeout_seconds.value policy.suspect_after -> Suspect
  | Some _ -> Healthy
let equal left right = left = right
let to_string = function Healthy -> "healthy" | Suspect -> "suspect" | Offline -> "offline"
