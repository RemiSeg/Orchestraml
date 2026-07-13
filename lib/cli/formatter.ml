module U = Yojson.Safe.Util
let json value = Yojson.Safe.pretty_to_string value
let string name value = U.member name value |> U.to_string
let int name value = U.member name value |> U.to_int
let job value = Printf.sprintf "%s  %-18s  %s" (string "id" value)
  (string "status" value) (string "name" value)
let jobs value = U.member "items" value |> U.to_list |> List.map job |> String.concat "\n"
let attempts value = U.member "items" value |> U.to_list |> List.map (fun item ->
  Printf.sprintf "#%-3d %s  %-12s  worker=%s" (int "attempt_number" item)
    (string "id" item) (string "status" item) (string "worker_id" item)) |> String.concat "\n"
let events value = U.member "items" value |> U.to_list |> List.map (fun item ->
  Printf.sprintf "%s  %s -> %s" (string "occurred_at" item)
    (string "from_status" item) (string "to_status" item)) |> String.concat "\n"
let worker value =
  let resources = U.member "resources" value in
  Printf.sprintf "%s  %-18s active=%d/%d cpu=%d/%d memory=%d/%d"
    (string "id" value) (string "name" value) (int "active_jobs" value)
    (int "max_concurrency" value) (int "reserved_cpu_millicores" resources)
    (int "cpu_millicores" resources) (int "reserved_memory_mib" resources)
    (int "memory_mib" resources)
let workers value = U.member "items" value |> U.to_list |> List.map worker |> String.concat "\n"
let log_entry ~attempt_id value =
  let sequence = int "sequence" value and stream = string "stream" value in
  let payload = string "payload_base64" value |> Base64.decode_exn in
  Printf.sprintf "[%s #%d %s] %s" attempt_id sequence stream payload
