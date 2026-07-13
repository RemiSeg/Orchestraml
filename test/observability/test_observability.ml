module Logger = Orchestraml_observability.Logger
module U = Yojson.Safe.Util

let test_structured_event () =
  let value = Logger.to_json ~level:Logger.Info ~component:"worker"
    ~event:"attempt_started" ~message:"attempt started"
    ~job_id:"job" ~attempt_id:"attempt" ~worker_id:"worker" () in
  Alcotest.(check string) "level" "info" U.(member "level" value |> to_string);
  Alcotest.(check string) "component" "worker" U.(member "component" value |> to_string);
  Alcotest.(check string) "event" "attempt_started" U.(member "event" value |> to_string);
  Alcotest.(check string) "job" "job" U.(member "job_id" value |> to_string);
  Alcotest.(check string) "attempt" "attempt" U.(member "attempt_id" value |> to_string);
  Alcotest.(check string) "worker" "worker" U.(member "worker_id" value |> to_string);
  Alcotest.(check bool) "timestamp present" true (U.member "timestamp" value <> `Null)

let () = Alcotest.run "orchestraml-observability" ["logging",[
  Alcotest.test_case "structured identifiers" `Quick test_structured_event]]
