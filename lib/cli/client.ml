type error = Invalid_url of string | Transport of string | Protocol of int * string * string
  | Invalid_response of string
type t = { client:Cohttp_eio.Client.t; base_uri:Uri.t;
  with_timeout:'a. (unit -> 'a) -> 'a }

let create ~client ~base_uri ~clock ~request_timeout =
  match Uri.scheme base_uri, Uri.host base_uri with
  | Some "http", Some _ when request_timeout > 0. ->
      Ok { client; base_uri; with_timeout=(fun operation ->
        Eio.Time.with_timeout_exn clock request_timeout operation) }
  | _ -> Error (Invalid_url "coordinator URL must be an absolute http URL")

let uri value path = Uri.resolve "http" value.base_uri (Uri.of_string path)
let decode_error status body =
  try
    let open Yojson.Safe.Util in
    let error = Yojson.Safe.from_string body |> member "error" in
    Protocol (status, member "code" error |> to_string, member "message" error |> to_string)
  with _ -> Protocol (status, "http_error", Printf.sprintf "coordinator returned HTTP %d" status)

let call ~sw value ?(headers=[]) meth path body =
  try value.with_timeout (fun () ->
    let headers = Cohttp.Header.of_list (("accept","application/json") :: headers) in
    let body = Cohttp_eio.Body.of_string (Option.value ~default:"" body) in
    let response, flow = Cohttp_eio.Client.call value.client ~sw ~headers ~body meth (uri value path) in
    let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
    let response_body = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow |> Eio.Buf_read.take_all in
    if status >= 200 && status < 300 then Ok response_body
    else Error (decode_error status response_body))
  with exn -> Error (Transport (Printexc.to_string exn))

let request_json ~sw value ?headers meth path body =
  let method' = match meth with `GET -> `GET | `POST -> `POST in
  let headers = match body with None -> Option.value ~default:[] headers
    | Some _ -> ("content-type","application/json") :: Option.value ~default:[] headers in
  match call ~sw value ~headers method' path body with
  | Error _ as error -> error
  | Ok "" -> Ok `Null
  | Ok body -> (try Ok (Yojson.Safe.from_string body)
      with Yojson.Json_error message -> Error (Invalid_response message))

let follow_logs ~sw value ~attempt_id ~after_sequence ~on_entry =
  let path = Printf.sprintf "/v1/attempts/%s/logs/follow?after_sequence=%d"
    attempt_id after_sequence in
  try
    let response, flow = Cohttp_eio.Client.call value.client ~sw
      ~headers:(Cohttp.Header.init_with "accept" "text/event-stream")
      ~body:(Cohttp_eio.Body.of_string "") `GET (uri value path) in
    let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
    if status <> 200 then
      let body = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow |> Eio.Buf_read.take_all in
      Error (decode_error status body)
    else
      let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
      let highest = ref after_sequence and id = ref None and data = Buffer.create 256 in
      let dispatch () = match !id with
        | None -> Buffer.clear data
        | Some sequence ->
            let payload = Buffer.contents data in Buffer.clear data; id := None;
            (try let json = Yojson.Safe.from_string payload in
              if sequence > !highest then (highest := sequence; on_entry sequence json)
             with Yojson.Json_error _ -> ()) in
      (try while true do
        let line = Eio.Buf_read.line reader in
        if line = "" then dispatch ()
        else if String.starts_with ~prefix:"id:" line then
          id := int_of_string_opt (String.trim (String.sub line 3 (String.length line - 3)))
        else if String.starts_with ~prefix:"data:" line then begin
          if Buffer.length data > 0 then Buffer.add_char data '\n';
          Buffer.add_string data (String.trim (String.sub line 5 (String.length line - 5)))
        end
      done; assert false with End_of_file -> dispatch ());
      Ok !highest
  with exn -> Error (Transport (Printexc.to_string exn))

let pp_error formatter = function
  | Invalid_url message | Transport message | Invalid_response message -> Format.pp_print_string formatter message
  | Protocol (_, code, message) -> Format.fprintf formatter "%s: %s" code message

let exit_code = function
  | Invalid_url _ | Invalid_response _ -> 2
  | Transport _ -> 6
  | Protocol (404,_,_) -> 4
  | Protocol (409,_,_) -> 5
  | Protocol (status,_,_) when status >= 400 && status < 500 -> 3
  | Protocol _ -> 1
