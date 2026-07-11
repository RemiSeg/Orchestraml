open Orchestraml_domain
open Foundation
open Identifiers
type cursor = { created_at : Timestamp.t; job_id : Job_id.t }
let encode value =
  Timestamp.to_rfc3339 value.created_at ^ "|" ^ Job_id.to_string value.job_id
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let decode value = try
  let decoded = Base64.decode_exn ~pad:false ~alphabet:Base64.uri_safe_alphabet value in
  match String.split_on_char '|' decoded with
  | [timestamp; id] ->
      (match Timestamp.of_rfc3339 timestamp, Job_id.of_string id with
       | Ok created_at, Ok job_id -> Ok { created_at; job_id }
       | _ -> Error "invalid cursor")
  | _ -> Error "invalid cursor"
  with _ -> Error "invalid cursor"
let validate_limit = function
  | None -> Ok 50
  | Some value when value >= 1 && value <= 100 -> Ok value
  | Some _ -> Error "limit must be between 1 and 100"
