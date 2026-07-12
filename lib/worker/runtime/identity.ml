open Orchestraml_domain.Identifiers
let read path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input) (fun () -> really_input_string input (in_channel_length input))
let rec ensure_directory path =
  if path = "." || path = Filename.dirname path || Sys.file_exists path then ()
  else (ensure_directory (Filename.dirname path); Unix.mkdir path 0o700)
let parse_existing path =
  try Worker_id.of_string (String.trim (read path))
    |> Result.map_error (fun _ -> "worker identity file contains an invalid UUID")
  with Sys_error message -> Error message
let load_or_create path =
  if Sys.file_exists path then parse_existing path
  else try
    ensure_directory (Filename.dirname path);
    let generator = Uuidm.v4_gen (Random.State.make_self_init ()) in
    let raw = generator () |> Uuidm.to_string in
    let temporary = Printf.sprintf "%s.%d.tmp" path (Unix.getpid ()) in
    let descriptor = Unix.openfile temporary [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
      output_string output (raw ^ "\n"); flush output; Unix.fsync descriptor);
    (try Unix.link temporary path; Unix.unlink temporary;
         Worker_id.of_string raw |> Result.map_error (fun _ -> "generated worker ID is invalid")
     with Unix.Unix_error (Unix.EEXIST, _, _) -> Unix.unlink temporary; parse_existing path)
  with
  | Unix.Unix_error (_, _, _) when Sys.file_exists path -> parse_existing path
  | Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error)
  | Sys_error message -> Error message
