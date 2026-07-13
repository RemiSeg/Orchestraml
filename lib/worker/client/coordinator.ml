open Orchestraml_domain
open Foundation
open Identifiers
open Shared
module U = Yojson.Safe.Util
type assignment = { job_id : Job_id.t; attempt_id : Attempt_id.t;
  attempt_number : Scalar.Attempt_number.t; execution : Execution_spec.t;
  timeout : Scalar.Timeout_seconds.t; resources : Resources.t }
type registration = { worker_id : Worker_id.t; name : string; labels : Worker_label.Set.t;
  max_concurrency : Scalar.Concurrency.t; resources : Resources.t }
type result_report = Succeeded of int | Failed of Failure.t | Timed_out | Cancelled
type control = Cancel of Attempt_id.t | Execution_timeout of Attempt_id.t | Stop_unknown of Attempt_id.t
type cleanup = Pending | Removed | Cleanup_failed
type container_metadata = { attempt_id:Attempt_id.t; worker_id:Worker_id.t;
  container_id:string; container_name:string; image_reference:string;
  created_at:Timestamp.t; started_at:Timestamp.t option; finished_at:Timestamp.t option;
  removed_at:Timestamp.t option; cleanup:cleanup }
type error = Transport of string | Protocol of int * string | Invalid_response of string
type t = { client : Cohttp_eio.Client.t; base_uri : Uri.t;
  with_timeout : 'a. (unit -> 'a) -> 'a }
let create ~client ~base_uri ~clock ~request_timeout = {
  client; base_uri; with_timeout = (fun operation ->
    Eio.Time.with_timeout_exn clock request_timeout operation) }
let uri value path = Uri.with_path value.base_uri path
let call ~sw value meth path json =
  try
    value.with_timeout (fun () ->
      let body = Yojson.Safe.to_string json |> Cohttp_eio.Body.of_string in
      let headers = Cohttp.Header.init_with "content-type" "application/json" in
      let response, response_body = Cohttp_eio.Client.call value.client ~sw ~headers ~body meth (uri value path) in
      let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
      let body = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) response_body |> Eio.Buf_read.take_all in
      Ok (status, body))
  with exn -> Error (Transport (Printexc.to_string exn))
let unit_response = function
  | Error _ as error -> error
  | Ok (status, _) when status >= 200 && status < 300 -> Ok ()
  | Ok (status, body) -> Error (Protocol (status, body))
let register ~sw value request =
  let labels = Worker_label.Set.elements request.labels |> List.map (fun label -> `String (Worker_label.value label)) in
  call ~sw value `PUT ("/v1/workers/" ^ Worker_id.to_string request.worker_id ^ "/registration")
    (`Assoc ["name",`String request.name;"labels",`List labels;
      "max_concurrency",`Int (Scalar.Concurrency.value request.max_concurrency);
      "resources",`Assoc ["cpu_millicores",`Int (Resources.cpu request.resources |> Scalar.Cpu_millicores.value);
        "memory_mib",`Int (Resources.memory request.resources |> Scalar.Memory_mib.value)]]) |> unit_response
let heartbeat ~sw value ~worker_id ~available_slots ~active_attempt_ids =
  call ~sw value `POST ("/v1/workers/" ^ Worker_id.to_string worker_id ^ "/heartbeat")
    (`Assoc ["available_slots",`Int available_slots;"active_attempt_ids",`List
      (List.map (fun id -> `String (Attempt_id.to_string id)) active_attempt_ids)]) |> unit_response
let unwrap = function Ok value -> value | Error _ -> failwith "invalid assignment value"
let execution json = match U.member "type" json |> U.to_string with
  | "command" -> Execution_spec.command ~executable:(U.member "executable" json |> U.to_string)
      ~arguments:(U.member "arguments" json |> U.to_list |> List.map U.to_string) |> unwrap
  | "container" -> Execution_spec.container ~image:(U.member "image" json |> U.to_string)
      ~command:(U.member "command" json |> U.to_list |> List.map U.to_string) |> unwrap
  | _ -> failwith "invalid assignment execution"
let poll ~sw value worker_id =
  match call ~sw value `POST ("/v1/workers/" ^ Worker_id.to_string worker_id ^ "/assignments/poll") `Null with
  | Error _ as error -> error | Ok (204, _) -> Ok None
  | Ok (200, body) -> (try let json = Yojson.Safe.from_string body in
      let resources = U.member "resources" json in
      Ok (Some { job_id = U.member "job_id" json |> U.to_string |> Job_id.of_string |> unwrap;
        attempt_id = U.member "attempt_id" json |> U.to_string |> Attempt_id.of_string |> unwrap;
        attempt_number = U.member "attempt_number" json |> U.to_int |> Scalar.Attempt_number.create |> unwrap;
        execution = U.member "execution" json |> execution;
        timeout = U.member "timeout_seconds" json |> U.to_int |> Scalar.Timeout_seconds.create |> unwrap;
        resources = Resources.create
          ~cpu:(U.member "cpu_millicores" resources |> U.to_int |> Scalar.Cpu_millicores.create |> unwrap)
          ~memory:(U.member "memory_mib" resources |> U.to_int |> Scalar.Memory_mib.create |> unwrap) })
    with _ -> Error (Invalid_response "coordinator returned an invalid assignment"))
  | Ok (status, body) -> Error (Protocol (status, body))
let poll_controls ~sw value worker_id =
  match call ~sw value `POST ("/v1/workers/" ^ Worker_id.to_string worker_id ^ "/controls/poll") `Null with
  | Error _ as error -> error | Ok (204, _) -> Ok []
  | Ok (200, body) ->
      (try
         let items = Yojson.Safe.from_string body |> U.member "items" |> U.to_list in
         Ok (List.map (fun json ->
           let id = U.member "attempt_id" json |> U.to_string |> Attempt_id.of_string |> unwrap in
           match U.member "type" json |> U.to_string with
           | "cancel" -> Cancel id | "execution_timeout" -> Execution_timeout id
           | "stop_unknown" -> Stop_unknown id
           | _ -> failwith "invalid control type") items)
       with _ -> Error (Invalid_response "coordinator returned invalid controls"))
  | Ok (status, body) -> Error (Protocol (status, body))
let empty ~sw value path = call ~sw value `POST path `Null |> unit_response
let acknowledge ~sw value id = empty ~sw value ("/v1/attempts/" ^ Attempt_id.to_string id ^ "/acknowledge")
let confirm_stopped ~sw value ~worker_id id = empty ~sw value ("/v1/workers/" ^ Worker_id.to_string worker_id
  ^ "/controls/" ^ Attempt_id.to_string id ^ "/stopped")
let started ~sw value id = empty ~sw value ("/v1/attempts/" ^ Attempt_id.to_string id ^ "/started")
let report ~sw value id report =
  let json = match report with
    | Succeeded code -> `Assoc ["type",`String "succeeded";"exit_code",`Int code]
    | Failed failure -> `Assoc ["type",`String "failed";"failure",`Assoc [
        "kind",`String (Failure.kind failure |> Failure.kind_to_string);
        "message",(match Failure.message failure with None -> `Null | Some value -> `String value)]]
    | Timed_out -> `Assoc ["type", `String "timed_out"]
    | Cancelled -> `Assoc ["type", `String "cancelled"] in
  call ~sw value `POST ("/v1/attempts/" ^ Attempt_id.to_string id ^ "/result") json |> unit_response
let upload_logs ~sw value ~worker_id ~attempt_id entries =
  let entry value = `Assoc [
    "sequence",`Int Log_entry.(sequence_number value |> sequence_value);
    "stream",`String (Log_entry.stream value |> Log_entry.stream_to_string);
    "observed_at",`String (Log_entry.observed_at value |> Timestamp.to_rfc3339);
    "payload_base64",`String (Base64.encode_exn (Log_entry.payload value))] in
  match call ~sw value `POST ("/v1/attempts/" ^ Attempt_id.to_string attempt_id ^ "/logs")
    (`Assoc ["worker_id",`String (Worker_id.to_string worker_id);
      "entries",`List (List.map entry entries)]) with
  | Error _ as error -> error
  | Ok (200, body) -> (try Ok (Yojson.Safe.from_string body |> U.member "highest_accepted_sequence" |> U.to_int)
      with _ -> Error (Invalid_response "coordinator returned invalid log acknowledgement"))
  | Ok (status, body) -> Error (Protocol (status, body))
let timestamp = function None->`Null|Some value->`String(Timestamp.to_rfc3339 value)
let container_json value = `Assoc ["worker_id",`String(Worker_id.to_string value.worker_id);
  "container_id",`String value.container_id;"container_name",`String value.container_name;
  "image_reference",`String value.image_reference;"created_at",`String(Timestamp.to_rfc3339 value.created_at);
  "started_at",timestamp value.started_at;"finished_at",timestamp value.finished_at;
  "removed_at",timestamp value.removed_at;"cleanup_outcome",`String(match value.cleanup with
    |Pending->"pending"|Removed->"removed"|Cleanup_failed->"failed")]
let record_container ~sw client metadata = call ~sw client `PUT
  ("/v1/attempts/"^Attempt_id.to_string metadata.attempt_id^"/container")
  (container_json metadata) |> unit_response
let timestamp_of_json name json=match U.member name json with `Null->None|value->
  Some(U.to_string value|>Timestamp.of_rfc3339|>unwrap)
let container_of_json json = {
  attempt_id=U.member "attempt_id" json|>U.to_string|>Attempt_id.of_string|>unwrap;
  worker_id=U.member "worker_id" json|>U.to_string|>Worker_id.of_string|>unwrap;
  container_id=U.member "container_id" json|>U.to_string;
  container_name=U.member "container_name" json|>U.to_string;
  image_reference=U.member "image_reference" json|>U.to_string;
  created_at=U.member "created_at" json|>U.to_string|>Timestamp.of_rfc3339|>unwrap;
  started_at=timestamp_of_json "started_at" json;finished_at=timestamp_of_json "finished_at" json;
  removed_at=timestamp_of_json "removed_at" json;cleanup=(match U.member "cleanup_outcome" json|>U.to_string with
    |"pending"->Pending|"removed"->Removed|"failed"->Cleanup_failed|_->failwith "invalid cleanup outcome")}
let find_container ~sw client attempt_id = match call ~sw client `GET
    ("/v1/attempts/"^Attempt_id.to_string attempt_id^"/container") `Null with
  |Error _ as error->error|Ok(404,_)->Ok None|Ok(200,body)->(try Ok(Some(Yojson.Safe.from_string body|>container_of_json))
      with _->Error(Invalid_response "coordinator returned invalid container metadata"))
  |Ok(status,body)->Error(Protocol(status,body))
let pp_error formatter = function
  | Transport message | Invalid_response message -> Format.pp_print_string formatter message
  | Protocol (status, body) -> Format.fprintf formatter "coordinator returned %d: %s" status body
let retryable = function Transport _ | Protocol (500, _) | Protocol (502, _)
  | Protocol (503, _) | Protocol (504, _) -> true | Protocol _ | Invalid_response _ -> false
