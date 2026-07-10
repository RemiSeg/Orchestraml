type entity_kind = Job | Attempt
type t = { entity_kind : entity_kind; from_status : string; action : string; reason : string }
let make ~entity_kind ~from_status ~action ~reason = { entity_kind; from_status; action; reason }
let pp formatter value = Format.fprintf formatter "%s: cannot %s from %s (%s)"
  (match value.entity_kind with Job -> "job" | Attempt -> "attempt")
  value.action value.from_status value.reason
