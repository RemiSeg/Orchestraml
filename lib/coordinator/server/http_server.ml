let read_body body =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) body in
  Eio.Buf_read.take_all reader
module Follow_source = struct
  type t = { router : Api.Router.t; sleep : float -> unit; interval : float;
    attempt_id : Orchestraml_domain.Identifiers.Attempt_id.t;
    mutable after_sequence : int; mutable buffered : string; mutable offset : int }
  let rec refill value =
    match Api.Router.follow_snapshot value.router ~attempt_id:value.attempt_id
        ~after_sequence:value.after_sequence with
    | Error _ -> raise End_of_file
    | Ok snapshot when snapshot.entries <> [] ->
        value.after_sequence <- snapshot.highest_sequence;
        value.buffered <- snapshot.entries |> List.map (fun entry ->
          let sequence = Orchestraml_domain.Shared.Log_entry.(sequence_number entry |> sequence_value) in
          Printf.sprintf "id: %d\ndata: %s\n\n" sequence
            (Dto.Log_json.entry entry |> Yojson.Safe.to_string)) |> String.concat "";
        value.offset <- 0
    | Ok snapshot when snapshot.terminal -> raise End_of_file
    | Ok _ -> value.sleep value.interval; refill value
  let single_read value destination =
    if value.offset = String.length value.buffered then refill value;
    let length = min (Cstruct.length destination) (String.length value.buffered - value.offset) in
    Cstruct.blit_from_string value.buffered value.offset destination 0 length;
    value.offset <- value.offset + length;
    length
  let read_methods = []
  let create ~router ~clock ~interval ~attempt_id ~after_sequence =
    let state = { router; sleep=(Eio.Time.sleep clock); interval; attempt_id; after_sequence;
      buffered=""; offset=0 } in
    let module Source = struct
      type nonrec t = t
      let single_read = single_read
      let read_methods = read_methods
    end in
    Eio.Resource.T (state, Eio.Flow.Pi.source (module Source))
end
let callback ~clock ~follow_interval router _connection request body =
  let meth = Cohttp.Request.meth request |> Cohttp.Code.string_of_method in
  let target = Cohttp.Request.resource request in
  let headers = Cohttp.Request.headers request |> Cohttp.Header.to_list in
  let response = Api.Router.handle router { meth; target; headers; body = read_body body } in
  let status = Cohttp.Code.status_of_code response.status in
  let headers = Cohttp.Header.of_list response.headers in
  match response.body with
  | Api.Router.Buffered body -> Cohttp_eio.Server.respond_string ~status ~headers ~body ()
  | Api.Router.Follow_logs { attempt_id; after_sequence } ->
      let body = Follow_source.create ~router ~clock ~interval:follow_interval
        ~attempt_id ~after_sequence in
      Cohttp_eio.Server.respond ~status ~headers ~body ()
let run ~sw ~net ~clock ~follow_interval ~listen_address ~port router =
  let address = match listen_address with
    | "127.0.0.1" -> Eio.Net.Ipaddr.V4.loopback
    | "0.0.0.0" -> Eio.Net.Ipaddr.V4.any
    | "::1" -> Eio.Net.Ipaddr.V6.loopback
    | "::" -> Eio.Net.Ipaddr.V6.any
    | value -> invalid_arg ("unsupported listen address: " ^ value) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 (`Tcp (address, port)) in
  let server = Cohttp_eio.Server.make ~callback:(callback ~clock ~follow_interval router) () in
  Cohttp_eio.Server.run socket server ~on_error:(fun error ->
    Format.eprintf "HTTP connection error: %s@." (Printexc.to_string error))
