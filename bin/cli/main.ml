open Cmdliner
module Client = Orchestraml_cli.Client
module Formatter = Orchestraml_cli.Formatter
module U = Yojson.Safe.Util

let fail error = Format.eprintf "%a@." Client.pp_error error; Stdlib.exit (Client.exit_code error)
let output ~json formatter value = print_endline (if json then Formatter.json value else formatter value)
let coordinator_url = Arg.(value & opt (some string) None & info ["coordinator-url"]
  ~docv:"URL" ~doc:"Coordinator base URL. Overrides ORCHESTRAML_COORDINATOR_URL.")
let json_output = Arg.(value & flag & info ["json"] ~doc:"Emit stable JSON output.")
let timeout = Arg.(value & opt float 10. & info ["timeout"] ~docv:"SECONDS"
  ~doc:"Timeout for non-streaming HTTP requests.")
let base_uri explicit = match explicit with Some value -> value | None ->
  Option.value ~default:"http://127.0.0.1:8080" (Sys.getenv_opt "ORCHESTRAML_COORDINATOR_URL")

let run_client explicit timeout operation =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let http = Cohttp_eio.Client.make ~https:None env#net in
  match Client.create ~client:http ~base_uri:(Uri.of_string (base_uri explicit))
      ~clock:env#clock ~request_timeout:timeout with
  | Error error -> fail error
  | Ok client -> operation env sw client

let request explicit timeout json formatter meth path ?headers body =
  run_client explicit timeout (fun _env sw client ->
    match Client.request_json ~sw client ?headers meth path body with
    | Error error -> fail error | Ok value -> output ~json formatter value)

let read_all path =
  if path = "-" then In_channel.input_all stdin
  else try In_channel.with_open_bin path In_channel.input_all
    with Sys_error message -> prerr_endline message; Stdlib.exit 2

let submit explicit timeout json idempotency_key file =
  let payload = read_all file in
  (try ignore (Yojson.Safe.from_string payload) with Yojson.Json_error message ->
    prerr_endline ("invalid JSON: " ^ message); Stdlib.exit 2);
  let headers = match idempotency_key with None -> [] | Some value -> ["idempotency-key",value] in
  request explicit timeout json Formatter.job `POST "/v1/jobs" ~headers (Some payload)

let jobs explicit timeout json status limit cursor =
  let query = ["status",status; "limit",Option.map string_of_int limit; "cursor",cursor]
    |> List.filter_map (fun (name,value) -> Option.map (fun value -> name ^ "=" ^ Uri.pct_encode value) value)
    |> String.concat "&" in
  let path = "/v1/jobs" ^ if query = "" then "" else "?" ^ query in
  request explicit timeout json Formatter.jobs `GET path None

let id_path prefix id suffix = prefix ^ Uri.pct_encode id ^ suffix
let status explicit timeout json id = request explicit timeout json Formatter.job `GET
  (id_path "/v1/jobs/" id "") None
let attempts explicit timeout json id = request explicit timeout json Formatter.attempts `GET
  (id_path "/v1/jobs/" id "/attempts") None
let events explicit timeout json id = request explicit timeout json Formatter.events `GET
  (id_path "/v1/jobs/" id "/events") None
let cancel explicit timeout json id = request explicit timeout json Formatter.job `POST
  (id_path "/v1/jobs/" id "/cancel") (Some "")
let workers explicit timeout json = request explicit timeout json Formatter.workers `GET "/v1/workers" None
let worker explicit timeout json id = request explicit timeout json Formatter.worker `GET
  (id_path "/v1/workers/" id "") None

let terminal_status = function "completed" | "permanently_failed" | "cancelled" -> true | _ -> false
let render_log ~json ~attempt_id entry =
  if json then print_endline (Yojson.Safe.to_string (`Assoc ["attempt_id",`String attempt_id;"entry",entry]))
  else print_endline (Formatter.log_entry ~attempt_id entry)
let attempts_json ~sw client job_id = match Client.request_json ~sw client `GET
    (id_path "/v1/jobs/" job_id "/attempts") None with
  | Ok value -> U.member "items" value |> U.to_list
  | Error error -> fail error
let stored_logs ~sw client ~json cursors attempt_id =
  let after = Option.value ~default:0 (Hashtbl.find_opt cursors attempt_id) in
  let path = Printf.sprintf "/v1/attempts/%s/logs?after_sequence=%d&limit=5000"
    (Uri.pct_encode attempt_id) after in
  match Client.request_json ~sw client `GET path None with
  | Error error -> fail error
  | Ok value ->
      U.member "items" value |> U.to_list |> List.iter (fun entry ->
        let sequence = U.member "sequence" entry |> U.to_int in
        Hashtbl.replace cursors attempt_id sequence; render_log ~json ~attempt_id entry)
let logs explicit timeout json selected_attempt follow job_id =
  run_client explicit timeout (fun env sw client ->
    let cursors = Hashtbl.create 8 in
    let load_attempts () = match selected_attempt with
      | Some id -> [id]
      | None -> attempts_json ~sw client job_id |> List.map (fun value -> U.member "id" value |> U.to_string) in
    List.iter (stored_logs ~sw client ~json cursors) (load_attempts ());
    if follow then begin
      let rec loop () =
        let ids = load_attempts () in
        (match List.rev ids with
         | [] -> Eio.Time.sleep env#clock 0.5
         | attempt_id :: _ ->
             let after = Option.value ~default:0 (Hashtbl.find_opt cursors attempt_id) in
             (match Client.follow_logs ~sw client ~attempt_id ~after_sequence:after
                 ~on_entry:(fun sequence entry -> Hashtbl.replace cursors attempt_id sequence;
                   render_log ~json ~attempt_id entry) with
              | Ok _ -> ()
              | Error (Client.Transport _) -> Eio.Time.sleep env#clock 1.
              | Error error -> fail error));
        match Client.request_json ~sw client `GET (id_path "/v1/jobs/" job_id "") None with
        | Error error -> fail error
        | Ok job when selected_attempt <> None || terminal_status (U.member "status" job |> U.to_string) -> ()
        | Ok _ -> loop () in
      loop ()
    end)

let common f = Term.(const f $ coordinator_url $ timeout $ json_output)
let job_id = Arg.(required & pos 0 (some string) None & info [] ~docv:"JOB_ID")
let submit_cmd = Cmd.v (Cmd.info "submit" ~doc:"Submit a job definition")
  Term.(common submit
    $ Arg.(value & opt (some string) None & info ["idempotency-key"] ~docv:"KEY")
    $ Arg.(required & pos 0 (some string) None & info [] ~docv:"JOB_JSON"))
let jobs_cmd = Cmd.v (Cmd.info "jobs" ~doc:"List jobs") Term.(common jobs
  $ Arg.(value & opt (some string) None & info ["status"] ~docv:"STATUS")
  $ Arg.(value & opt (some int) None & info ["limit"] ~docv:"COUNT")
  $ Arg.(value & opt (some string) None & info ["cursor"] ~docv:"CURSOR"))
let simple name doc f = Cmd.v (Cmd.info name ~doc) Term.(common f $ job_id)
let logs_cmd = Cmd.v (Cmd.info "logs" ~doc:"Retrieve or follow job attempt logs") Term.(common logs
  $ Arg.(value & opt (some string) None & info ["attempt"] ~docv:"ATTEMPT_ID")
  $ Arg.(value & flag & info ["follow"] ~doc:"Follow logs until the job is terminal") $ job_id)
let workers_cmd = Cmd.v (Cmd.info "workers" ~doc:"List registered workers") (common workers)
let worker_cmd = Cmd.v (Cmd.info "worker" ~doc:"Inspect a worker") Term.(common worker
  $ Arg.(required & pos 0 (some string) None & info [] ~docv:"WORKER_ID"))
let commands = [submit_cmd; jobs_cmd; simple "status" "Inspect a job" status;
  simple "attempts" "List job attempts" attempts; simple "events" "List job events" events;
  logs_cmd; simple "cancel" "Cancel a job" cancel; workers_cmd; worker_cmd]
let () = Stdlib.exit (Cmd.eval (Cmd.group (Cmd.info "orchestraml" ~version:"1.0.0") commands))
