open Orchestraml_domain
open Foundation
open Identifiers
open Shared
type outcome = Succeeded of int | Failed of Failure.t
type cleanup = Pending | Removed | Cleanup_failed
type metadata = { attempt_id:Attempt_id.t; worker_id:Worker_id.t; container_id:string;
  container_name:string; image_reference:string; created_at:Timestamp.t;
  started_at:Timestamp.t option; finished_at:Timestamp.t option;
  removed_at:Timestamp.t option; cleanup:cleanup }
let now () = Ptime_clock.now () |> Timestamp.of_ptime
let resolve_executable executable =
  if not (Filename.is_implicit executable) then executable
  else Sys.getenv_opt "PATH" |> Option.value ~default:"/usr/local/bin:/usr/bin:/bin"
    |> String.split_on_char ':' |> List.find_map (fun directory ->
      let candidate = Filename.concat directory executable in
      if Sys.file_exists candidate then Some candidate else None)
    |> Option.value ~default:executable
module Capture = struct
  type t = { buffer:Buffer.t; emit:(string -> unit) option }
  let single_write value buffers = List.fold_left (fun total data ->
    let text=Cstruct.to_string data in Buffer.add_string value.buffer text;
    Option.iter (fun emit -> emit text) value.emit; total + Cstruct.length data) 0 buffers
  let copy value ~src = let buffer=Cstruct.create 4096 in try while true do
    let n=Eio.Flow.single_read src buffer in ignore(single_write value [Cstruct.sub buffer 0 n]) done
    with End_of_file -> ()
  let create ?emit () = let value={buffer=Buffer.create 128;emit} in
    let module Sink=struct type nonrec t=t let single_write=single_write let copy=copy end in
    value,Eio.Resource.T(value,Eio.Flow.Pi.sink(module Sink))
end
let run ~sw ~process_mgr ~executable ?stdout ?stderr args = try
  let executable = resolve_executable executable in
  let process=Eio.Process.spawn ~sw process_mgr ?stdout ?stderr ~executable (executable::args) in
  Ok(Eio.Process.await process) with exn -> Error exn
let capture ~sw ~process_mgr ~executable args =
  let out,sink=Capture.create() in match run ~sw ~process_mgr ~executable ~stdout:sink ~stderr:sink args with
  | Ok status -> status,Buffer.contents out.buffer | Error exn -> `Signaled (-1),Printexc.to_string exn
let success = function `Exited 0 -> true | _ -> false
let capability ~sw ~process_mgr ~executable =
  let status,_=capture ~sw ~process_mgr ~executable ["version"] in success status
let short id = let value=Worker_id.to_string id in String.sub value 0 8
type running={capture:string list->Eio.Process.exit_status*string;
  follow:(unit->unit);name:string; mutable data:metadata;
  mutable active:bool; mutable outcome:outcome option}
let metadata value=value.data
let prepare ~sw ~process_mgr ~executable ~worker_id ~job_id ~attempt_id ~resources ~on_output ~image ~command =
  let inspect,_=capture ~sw ~process_mgr ~executable ["image";"inspect";image] in
  let available=if success inspect then true else let pulled,_=capture ~sw ~process_mgr ~executable ["pull";image] in success pulled in
  if not available then Error(Failure.create ~message:("Docker image unavailable: "^image) Failure.Invalid_container_image)
  else
    let name="orchestraml-"^short worker_id^"-"^Attempt_id.to_string attempt_id in
    let cpu=Resources.cpu resources|>Scalar.Cpu_millicores.value and memory=Resources.memory resources|>Scalar.Memory_mib.value in
    let limits=(if cpu=0 then [] else ["--cpus";Printf.sprintf "%.3f" (float cpu/.1000.)])@
      (if memory=0 then [] else ["--memory";string_of_int memory^"m"]) in
    let args=["create";"--name";name;"--cap-drop";"ALL";"--security-opt";"no-new-privileges";
      "--label";"orchestraml.managed=true";"--label";"orchestraml.job_id="^Job_id.to_string job_id;
      "--label";"orchestraml.attempt_id="^Attempt_id.to_string attempt_id;
      "--label";"orchestraml.worker_id="^Worker_id.to_string worker_id]@limits@[image]@command in
    let created,output=capture ~sw ~process_mgr ~executable args in
    if not(success created) then Error(Failure.create ~message:output Failure.Invalid_configuration)
    else
      let capture_args args=capture ~sw ~process_mgr ~executable args in
      let follow ()=
        let _,out_sink=Capture.create ~emit:(on_output Log_entry.Stdout)() in
        let _,err_sink=Capture.create ~emit:(on_output Log_entry.Stderr)() in
        ignore(run ~sw ~process_mgr ~executable ~stdout:out_sink ~stderr:err_sink ["logs";"--follow";name]) in
      let data={attempt_id;worker_id;container_id=String.trim output;container_name=name;
        image_reference=image;created_at=now();started_at=None;finished_at=None;removed_at=None;cleanup=Pending} in
      Ok{capture=capture_args;follow;name;data;active=false;outcome=None}
let activate value = if value.active then Ok () else
  let started,output=value.capture ["start";value.name] in
  if success started then (value.active<-true;value.data<-{value.data with started_at=Some(now())};Ok())
  else Error(Failure.create ~message:("Docker container did not start: "^output) Failure.Temporary_execution_failure)
let discard value = if value.outcome=None then let removed,_=value.capture ["rm";"-f";value.name] in
  value.data<-{value.data with finished_at=(if value.active then Some(now()) else value.data.finished_at);
    removed_at=(if success removed then Some(now()) else None);
    cleanup=(if success removed then Removed else Cleanup_failed)}
let await value=match value.outcome with Some outcome->outcome|None->
  let exit_code=ref 1 in
  Eio.Fiber.both
    value.follow
    (fun()->let status,output=value.capture ["wait";value.name] in
      if success status then exit_code:=String.trim output|>int_of_string_opt|>Option.value~default:1);
  value.data<-{value.data with finished_at=Some(now())};
  let removed,_=value.capture ["rm";"-f";value.name] in
  value.data<-if success removed then {value.data with removed_at=Some(now());cleanup=Removed}
    else {value.data with removed_at=None;cleanup=Cleanup_failed};
  let outcome=if !exit_code=0 then Succeeded 0 else Failed(Failure.create
    ~message:(Printf.sprintf "container exited with code %d" !exit_code) Failure.Temporary_execution_failure) in
  value.outcome<-Some outcome;outcome
let stop ~grace value = if value.outcome=None then begin
  ignore(value.capture ["stop";"--time";string_of_int(max 1(int_of_float grace));value.name]);
  ignore(value.capture ["kill";value.name]) end
let is_finished value=Option.is_some value.outcome
let cleanup_orphans ~sw ~process_mgr ~executable ~worker_id =
  let status,output=capture ~sw ~process_mgr ~executable ["ps";"-aq";"--filter";"label=orchestraml.managed=true";
    "--filter";"label=orchestraml.worker_id="^Worker_id.to_string worker_id] in
  if not(success status) then [] else output|>String.split_on_char '\n'|>List.filter_map(fun raw->
    let id=String.trim raw in if id="" then None else
    let inspected,details=capture ~sw ~process_mgr ~executable ["inspect";"--format";
      "{{.Id}}|{{.Name}}|{{.Config.Image}}|{{.Created}}|{{index .Config.Labels \"orchestraml.attempt_id\"}}";id] in
    let removed,_=capture ~sw ~process_mgr ~executable ["rm";"-f";id] in
    if not(success inspected) then None else match String.trim details|>String.split_on_char '|' with
    | [container_id;name;image;created;attempt] -> (match Attempt_id.of_string attempt,Timestamp.of_rfc3339 created with
      | Ok attempt_id,Ok created_at -> Some {attempt_id;worker_id;container_id;
          container_name=(if String.starts_with ~prefix:"/" name then String.sub name 1 (String.length name-1) else name);
          image_reference=image;created_at;started_at=None;finished_at=None;
          removed_at=(if success removed then Some(now()) else None);
          cleanup=(if success removed then Removed else Cleanup_failed)}
      | _ -> None)
    | _ -> None)
