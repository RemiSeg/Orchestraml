type t = { database_url : Uri.t; listen_address : string; port : int;
  db_pool_size : int; migrations_dir : string; log_level : string }
let env name default = match Sys.getenv_opt name with Some value -> value | None -> default
let int_env errors name default ~min ~max =
  match int_of_string_opt (env name (string_of_int default)) with
  | Some value when value >= min && value <= max -> value
  | _ -> errors := (Printf.sprintf "%s must be between %d and %d" name min max) :: !errors; default
let load () =
  let errors = ref [] in
  let database_url = match Sys.getenv_opt "DATABASE_URL" with
    | Some value when String.trim value <> "" -> Uri.of_string value
    | _ -> errors := "DATABASE_URL is required" :: !errors; Uri.empty in
  let port = int_env errors "PORT" 8080 ~min:1 ~max:65535 in
  let db_pool_size = int_env errors "DB_POOL_SIZE" 10 ~min:1 ~max:100 in
  let value = { database_url; listen_address = env "LISTEN_ADDRESS" "127.0.0.1";
    port; db_pool_size; migrations_dir = env "MIGRATIONS_DIR" "migrations";
    log_level = env "LOG_LEVEL" "info" } in
  match List.rev !errors with [] -> Ok value | errors -> Error errors
