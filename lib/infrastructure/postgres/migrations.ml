type error = Invalid_files of string | Database_error of string
type migration = { version : int; filename : string; checksum : string; sql : string }
let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    really_input_string channel (in_channel_length channel))
let parse_file directory filename =
  try
    let version = String.sub filename 0 3 |> int_of_string in
    if String.length filename < 8 || not (Filename.check_suffix filename ".sql") then None
    else let path = Filename.concat directory filename in
      let sql = read_file path in
      Some { version; filename; checksum = Digest.string sql |> Digest.to_hex; sql }
  with _ -> None
let discover directory =
  if not (Sys.file_exists directory && Sys.is_directory directory) then
    Error (Invalid_files ("migration directory does not exist: " ^ directory))
  else
    let files = Sys.readdir directory |> Array.to_list |> List.filter_map (parse_file directory)
      |> List.sort (fun left right -> Int.compare left.version right.version) in
    let rec validate expected = function
      | [] -> Ok files
      | value :: rest when value.version = expected -> validate (expected + 1) rest
      | value :: _ -> Error (Invalid_files (Printf.sprintf "expected migration %03d, found %03d" expected value.version)) in
    validate 1 files
let applied_request = Caqti_request.Infix.(Caqti_type.unit ->* Caqti_type.(t3 int string string))
  "SELECT version, filename, checksum FROM schema_migrations ORDER BY version"
let migrations_table_request = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.(option string))
  "SELECT to_regclass('public.schema_migrations')::text"
let migration_request sql =
  Caqti_request.Infix.(Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql
let record_request = Caqti_request.Infix.(Caqti_type.(t3 int string string) ->. Caqti_type.unit)
  "INSERT INTO schema_migrations(version, filename, checksum) VALUES (?, ?, ?)"
let with_connection pool operation =
  match Caqti_eio.Pool.use (fun connection -> Ok (operation connection)) pool with
  | Ok result -> result
  | Error error -> Error (Database_error (Caqti_error.show error))
let load_applied (module Db : Caqti_eio.CONNECTION) = match Db.collect_list applied_request () with
  | Ok values -> Ok values | Error error -> Error (Database_error (Caqti_error.show error))
let compare_applied migrations applied =
  let rec loop migrations applied = match migrations, applied with
    | _, [] -> Ok migrations
    | [], _ :: _ -> Error (Invalid_files "database schema is newer than this executable")
    | migration :: migrations, (version, filename, checksum) :: applied ->
        if migration.version <> version || not (String.equal migration.filename filename)
          || not (String.equal migration.checksum checksum) then
          Error (Invalid_files ("applied migration differs: " ^ filename))
        else loop migrations applied in
  loop migrations applied
let migrations_table_exists (module Db : Caqti_eio.CONNECTION) =
  match Db.find migrations_table_request () with
  | Ok (Some _) -> Ok true
  | Ok None -> Ok false
  | Error error -> Error (Database_error (Caqti_error.show error))
let check_current pool ~directory = match discover directory with
  | Error _ as error -> error
  | Ok migrations -> with_connection pool (fun ((module Db : Caqti_eio.CONNECTION) as connection) -> match load_applied connection with
      | Error _ as error -> error
      | Ok applied -> match compare_applied migrations applied with
          | Ok [] -> Ok () | Ok _ -> Error (Invalid_files "pending migrations")
          | Error _ as error -> error)
let apply_one (module Db : Caqti_eio.CONNECTION) migration =
  match Db.start () with
  | Error error -> Error (Database_error (Caqti_error.show error))
  | Ok () ->
      let finish result = match result with
        | Ok () -> (match Db.commit () with Ok () -> Ok ()
            | Error error -> Error (Database_error (Caqti_error.show error)))
        | Error _ as error -> ignore (Db.rollback ()); error in
      let statements = String.split_on_char ';' migration.sql
        |> List.map String.trim |> List.filter (fun sql -> sql <> "") in
      let rec execute = function
        | [] -> Ok ()
        | sql :: rest ->
            (match Db.exec (migration_request sql) () with
             | Ok () -> execute rest
             | Error error -> Error (Database_error (Caqti_error.show error))) in
      finish (match execute statements with
        | Error _ as error -> error
        | Ok () -> match Db.exec record_request
            (migration.version, migration.filename, migration.checksum) with
            | Ok () -> Ok () | Error error -> Error (Database_error (Caqti_error.show error)))
let apply pool ~directory = match discover directory with
  | Error _ as error -> error
  | Ok migrations -> with_connection pool (fun ((module Db : Caqti_eio.CONNECTION) as connection) ->
      let applied = match migrations_table_exists connection with
        | Error _ as error -> error
        | Ok true -> load_applied connection
        | Ok false -> (match migrations with
            | [] -> Error (Invalid_files "migration 001 is required to create schema_migrations")
            | first :: _ -> match apply_one (module Db) first with
                | Error _ as error -> error
                | Ok () -> load_applied connection) in
      match applied with
      | Error _ as error -> error
      | Ok applied -> match compare_applied migrations applied with
          | Error _ as error -> error
          | Ok pending ->
              let rec loop = function [] -> Ok () | migration :: rest ->
                match apply_one (module Db) migration with Ok () -> loop rest | Error _ as error -> error in
              loop pending)
