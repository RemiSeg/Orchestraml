open Orchestraml_domain
open Foundation
open Identifiers
open Shared
module U = Yojson.Safe.Util
let unwrap = function Ok value -> value | Error error ->
  failwith (Format.asprintf "%a" Validation_error.pp error)
let decode_batch ~attempt_id json = try
  let worker_id = U.member "worker_id" json |> U.to_string |> Worker_id.of_string |> unwrap in
  let entries = U.member "entries" json |> U.to_list |> List.map (fun value ->
    let sequence = U.member "sequence" value |> U.to_int |> Log_entry.sequence |> unwrap in
    let stream = U.member "stream" value |> U.to_string |> Log_entry.stream_of_string |> unwrap in
    let observed_at = U.member "observed_at" value |> U.to_string |> Timestamp.of_rfc3339 |> unwrap in
    let payload = U.member "payload_base64" value |> U.to_string |> Base64.decode_exn in
    Log_entry.create ~attempt_id ~sequence ~stream ~observed_at ~payload |> unwrap) in
  Ok (worker_id, entries)
  with Yojson.Safe.Util.Type_error (message, _) | Yojson.Safe.Util.Undefined (message, _)
    | Failure message -> Error [message] | Invalid_argument message -> Error [message]
let entry value = `Assoc [
  "sequence", `Int Log_entry.(sequence_number value |> sequence_value);
  "stream", `String (Log_entry.stream value |> Log_entry.stream_to_string);
  "observed_at", `String (Log_entry.observed_at value |> Timestamp.to_rfc3339);
  "payload_base64", `String (Base64.encode_exn (Log_entry.payload value))]
