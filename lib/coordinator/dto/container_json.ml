open Orchestraml_domain
open Foundation
open Identifiers
module Persistence = Orchestraml_application.Ports.Persistence
module U = Yojson.Safe.Util
let option_timestamp name json = match U.member name json with
  | `Null -> Ok None
  | value -> (try U.to_string value |> Timestamp.of_rfc3339 |> Result.map Option.some
    with _ -> Error { Validation_error.field=name; message="must be an RFC3339 timestamp or null" })
let decode ~attempt_id json = try
  let worker_id = U.member "worker_id" json |> U.to_string |> Worker_id.of_string in
  let created_at = U.member "created_at" json |> U.to_string |> Timestamp.of_rfc3339 in
  let started_at = option_timestamp "started_at" json
  and finished_at = option_timestamp "finished_at" json
  and removed_at = option_timestamp "removed_at" json in
  let cleanup_outcome = match U.member "cleanup_outcome" json |> U.to_string with
    | "pending" -> Ok Persistence.Pending | "removed" -> Ok Persistence.Removed
    | "failed" -> Ok Persistence.Cleanup_failed
    | _ -> Error { Validation_error.field="cleanup_outcome"; message="must be pending, removed, or failed" } in
  match worker_id,created_at,started_at,finished_at,removed_at,cleanup_outcome with
  | Ok worker_id,Ok created_at,Ok started_at,Ok finished_at,Ok removed_at,Ok cleanup_outcome ->
      let metadata : Persistence.container_metadata = { attempt_id; worker_id;
        container_id=U.member "container_id" json |> U.to_string;
        container_name=U.member "container_name" json |> U.to_string;
        image_reference=U.member "image_reference" json |> U.to_string;
        created_at; started_at; finished_at; removed_at; cleanup_outcome } in
      if String.trim metadata.container_id="" || String.trim metadata.container_name=""
         || String.trim metadata.image_reference="" then Error ["container identity fields must be non-empty"]
      else Ok (worker_id,metadata)
  | values ->
      let errors = [match values with
        | Error e,_,_,_,_,_ | _,Error e,_,_,_,_ | _,_,Error e,_,_,_
        | _,_,_,Error e,_,_ | _,_,_,_,Error e,_ | _,_,_,_,_,Error e ->
            e.Validation_error.field ^ " " ^ e.message
        | _ -> "invalid container metadata"] in Error errors
  with _ -> Error ["container metadata JSON is invalid"]
let timestamp = function None -> `Null | Some value -> `String (Timestamp.to_rfc3339 value)
let encode (value : Persistence.container_metadata) = `Assoc [
  "attempt_id",`String (Attempt_id.to_string value.attempt_id);
  "worker_id",`String (Worker_id.to_string value.worker_id);
  "container_id",`String value.container_id; "container_name",`String value.container_name;
  "image_reference",`String value.image_reference;
  "created_at",`String (Timestamp.to_rfc3339 value.created_at);
  "started_at",timestamp value.started_at; "finished_at",timestamp value.finished_at;
  "removed_at",timestamp value.removed_at;
  "cleanup_outcome",`String (match value.cleanup_outcome with
    | Persistence.Pending -> "pending" | Persistence.Removed -> "removed"
    | Persistence.Cleanup_failed -> "failed")]
