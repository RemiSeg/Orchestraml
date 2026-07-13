module Formatter = Orchestraml_cli.Formatter
module Client = Orchestraml_cli.Client
let contains text needle =
  let rec loop index = index + String.length needle <= String.length text
    && (String.sub text index (String.length needle) = needle || loop (index + 1)) in
  needle = "" || loop 0

let test_format_job () =
  let json = Yojson.Safe.from_string
    {|{"id":"00000000-0000-4000-8000-000000000001","status":"running","name":"demo"}|} in
  let rendered = Formatter.job json in
  Alcotest.(check bool) "contains status" true
    (contains rendered "running")

let test_format_binary_log () =
  let json = `Assoc ["sequence",`Int 1;"stream",`String "stdout";
    "payload_base64",`String (Base64.encode_exn "hello\000world")] in
  let rendered = Formatter.log_entry ~attempt_id:"attempt" json in
  Alcotest.(check bool) "binary payload retained" true (String.length rendered > 20)

let test_exit_codes () =
  Alcotest.(check int) "not found" 4 (Client.exit_code (Client.Protocol (404,"not_found","missing")));
  Alcotest.(check int) "conflict" 5 (Client.exit_code (Client.Protocol (409,"conflict","conflict")));
  Alcotest.(check int) "transport" 6 (Client.exit_code (Client.Transport "offline"))

let () = Alcotest.run "orchestraml-cli" ["formatting",[
  Alcotest.test_case "job" `Quick test_format_job;
  Alcotest.test_case "binary log" `Quick test_format_binary_log;
  Alcotest.test_case "exit codes" `Quick test_exit_codes]]
