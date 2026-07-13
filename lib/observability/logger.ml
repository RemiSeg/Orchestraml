type level = Debug | Info | Warning | Error

let level_name = function Debug -> "debug" | Info -> "info"
  | Warning -> "warning" | Error -> "error"

let to_json ~level ~component ~event ~message ?job_id ?attempt_id ?worker_id () =
  let optional name = function None -> [] | Some value -> [name, `String value] in
  let fields = [
    "timestamp", `String (Ptime.to_rfc3339 ~frac_s:3 (Ptime_clock.now ()));
    "level", `String (level_name level); "component", `String component;
    "event", `String event; "message", `String message ]
    @ optional "job_id" job_id @ optional "attempt_id" attempt_id
    @ optional "worker_id" worker_id in
  `Assoc fields

let emit ~level ~component ~event ~message ?job_id ?attempt_id ?worker_id () =
  let json = to_json ~level ~component ~event ~message ?job_id ?attempt_id ?worker_id () in
  output_string stderr (Yojson.Safe.to_string json);
  output_char stderr '\n'; flush stderr
