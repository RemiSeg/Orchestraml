open Orchestraml_domain.Shared
type outcome = Succeeded of int | Failed of Failure.t
type termination = Exited_during_grace | Force_killed | Already_exited
module Tail = struct
  type t = { buffer : Buffer.t; limit : int }
  let trim value =
    let length = Buffer.length value.buffer in
    if length > value.limit then
      let retained = Buffer.sub value.buffer (length - value.limit) value.limit in
      Buffer.clear value.buffer; Buffer.add_string value.buffer retained
  let single_write ?on_output ?stream value buffers =
    (match on_output,stream with Some emit,Some stream -> List.iter (fun data -> emit stream (Cstruct.to_string data)) buffers | _ -> ());
    List.iter (fun data -> Buffer.add_string value.buffer (Cstruct.to_string data)) buffers;
    trim value;
    List.fold_left (fun total data -> total + Cstruct.length data) 0 buffers
  let copy ?on_output ?stream value ~src =
    let buffer = Cstruct.create 4096 in
    try while true do
      let length = Eio.Flow.single_read src buffer in
      ignore (single_write ?on_output ?stream value [Cstruct.sub buffer 0 length])
    done with End_of_file -> ()
  let create ?on_output ?stream limit =
    let value = { buffer = Buffer.create (min limit 4096); limit } in
    let module Sink = struct
      type nonrec t = t
      let single_write value buffers = single_write ?on_output ?stream value buffers
      let copy value ~src = copy ?on_output ?stream value ~src
    end in
    value, Eio.Resource.T (value, Eio.Flow.Pi.sink (module Sink))
  let contents value = Buffer.contents value.buffer
end
type running = { wait : unit -> Eio.Process.exit_status; terminate_process : unit -> unit;
  kill_process : unit -> unit; stdout : Tail.t; stderr : Tail.t; mutable outcome : outcome option }
let contains text needle =
  let rec loop index =
    index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1)) in
  needle = "" || loop 0
let classify_start_error exn =
  let message = Printexc.to_string exn and normalized = Printexc.to_string exn |> String.lowercase_ascii in
  let kind =
    if contains normalized "permission denied" || contains normalized "eacces" then Failure.Permission_denied
    else if contains normalized "executable not found" || contains normalized "no such file"
      || contains normalized "enoent" then Failure.Missing_executable
    else Failure.Invalid_command in
  Failure.create ~message kind
let start ~sw ~process_mgr ?on_output specification =
  Execution_spec.fold specification
    ~container:(fun _ _ -> Error (Failure.create ~message:"container execution begins in Phase 6"
      Failure.Invalid_configuration))
    ~command:(fun executable arguments ->
      try
        let stdout, stdout_sink = Tail.create ?on_output ~stream:Log_entry.Stdout (64 * 1024) in
        let stderr, stderr_sink = Tail.create ?on_output ~stream:Log_entry.Stderr (64 * 1024) in
        let process = Eio.Process.spawn ~sw process_mgr ~stdout:stdout_sink ~stderr:stderr_sink
          ~executable (executable :: arguments) in
        Ok { wait = (fun () -> Eio.Process.await process);
          terminate_process = (fun () -> Eio.Process.signal process Sys.sigterm);
          kill_process = (fun () -> Eio.Process.signal process Sys.sigkill); stdout; stderr; outcome = None }
      with exn -> Error (classify_start_error exn))
let await running = match running.outcome with Some outcome -> outcome | None ->
  let result = running.wait () in
  Eio.Fiber.yield ();
  let outcome = match result with
        | `Exited 0 -> Succeeded 0
        | `Exited code ->
            let stderr = String.trim (Tail.contents running.stderr) in
            let stdout = String.trim (Tail.contents running.stdout) in
            let diagnostic = if stderr <> "" then stderr else stdout in
            Failed (Failure.create
            ~message:(if diagnostic = "" then Printf.sprintf "process exited with code %d" code
              else Printf.sprintf "process exited with code %d: %s" code diagnostic)
            Failure.Temporary_execution_failure)
        | `Signaled signal -> Failed (Failure.create
            ~message:(Printf.sprintf "process terminated by signal %d" signal)
            Failure.Temporary_execution_failure) in
  running.outcome <- Some outcome; outcome
let terminate running = running.terminate_process ()
let kill running = running.kill_process ()
let stop ~clock ~grace running = match running.outcome with
  | Some _ -> Already_exited
  | None -> terminate running;
      try ignore (Eio.Time.with_timeout_exn clock grace (fun () -> await running)); Exited_during_grace
      with Eio.Time.Timeout -> kill running; ignore (await running); Force_killed
let is_finished running = Option.is_some running.outcome
