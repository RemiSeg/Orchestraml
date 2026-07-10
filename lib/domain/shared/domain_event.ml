open Foundation
open Identifiers

type entity = Job of Job_id.t | Attempt of Attempt_id.t
type t = { entity : entity; from_status : string; to_status : string; occurred_at : Timestamp.t; reason : string option }
let make ?reason ~entity ~from_status ~to_status ~occurred_at () =
  { entity; from_status; to_status; occurred_at; reason }
