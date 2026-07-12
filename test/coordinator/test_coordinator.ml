open Orchestraml_application
module Support = Orchestraml_test_support
module Router = Orchestraml_coordinator.Api.Router
let get_ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture error"
let timestamp = Orchestraml_domain.Foundation.Timestamp.of_rfc3339 "2026-01-01T00:00:00Z" |> get_ok
let fixture () =
  let persistence = Memory.Persistence.create () in
  let clock = Support.Controlled_clock.create timestamp |> Support.Controlled_clock.port in
  let ids = Support.Deterministic_ids.create () |> Support.Deterministic_ids.port in
  let jobs = Services.Job_service.create ~persistence ~clock ~ids in
  let workers = Services.Worker_service.create ~persistence ~clock ~ids in
  let seconds value = Orchestraml_domain.Foundation.Scalar.Timeout_seconds.create value |> get_ok in
  let health_policy = Orchestraml_domain.Shared.Worker_health.create
    ~suspect_after:(seconds 30) ~offline_after:(seconds 60) |> get_ok in
  let scheduling = Services.Scheduling_service.create ~persistence ~clock ~ids ~health_policy in
  let execution = Services.Execution_service.create ~persistence ~clock in
  Router.create ~jobs ~workers ~scheduling ~execution ~health:(fun () -> true), persistence
let router () = fst (fixture ())
let request ?(headers=[]) ?(body="") meth target = { Router.meth = meth; target; headers; body }
let valid_body = {|{"name":"api-job","execution":{"type":"command","executable":"true","arguments":[]},"timeout_seconds":30,"max_attempts":2,"retry":{"initial_delay_seconds":5,"multiplier":2,"maximum_delay_seconds":20,"retry_timeouts":true}}|}
let test_submit_and_get () =
  let router = router () in
  let created = Router.handle router (request ~body:valid_body "POST" "/v1/jobs") in
  Alcotest.(check int) "created" 201 created.status;
  let id = Yojson.Safe.from_string created.body |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  let found = Router.handle router (request "GET" ("/v1/jobs/" ^ id)) in
  Alcotest.(check int) "found" 200 found.status
let test_idempotency_and_validation () =
  let router = router () and headers = ["Idempotency-Key","api-request"] in
  let first = Router.handle router (request ~headers ~body:valid_body "POST" "/v1/jobs") in
  let replay = Router.handle router (request ~headers ~body:valid_body "POST" "/v1/jobs") in
  Alcotest.(check int) "first" 201 first.status;
  Alcotest.(check int) "replay" 200 replay.status;
  let invalid = Router.handle router (request ~body:"{}" "POST" "/v1/jobs") in
  Alcotest.(check int) "invalid" 400 invalid.status
let test_health_and_missing () =
  let router = router () in
  Alcotest.(check int) "health" 200 (Router.handle router (request "GET" "/health")).status;
  Alcotest.(check int) "missing" 404
    (Router.handle router (request "GET" "/v1/jobs/00000000-0000-4000-8000-000000000099")).status
let test_pagination_validation () =
  let router = router () in
  ignore (Router.handle router (request ~body:valid_body "POST" "/v1/jobs"));
  ignore (Router.handle router (request ~body:valid_body "POST" "/v1/jobs"));
  let first = Router.handle router (request "GET" "/v1/jobs?status=pending&limit=1") in
  Alcotest.(check int) "first page" 200 first.status;
  let json = Yojson.Safe.from_string first.body in
  let items = Yojson.Safe.Util.member "items" json |> Yojson.Safe.Util.to_list in
  Alcotest.(check int) "one item" 1 (List.length items);
  let cursor = Yojson.Safe.Util.member "next_cursor" json |> Yojson.Safe.Util.to_string in
  let second = Router.handle router (request "GET" ("/v1/jobs?limit=1&cursor=" ^ Uri.pct_encode cursor)) in
  Alcotest.(check int) "second page" 200 second.status;
  Alcotest.(check int) "invalid status" 400
    (Router.handle router (request "GET" "/v1/jobs?status=unknown")).status;
  Alcotest.(check int) "invalid limit" 400
    (Router.handle router (request "GET" "/v1/jobs?limit=nope")).status;
  Alcotest.(check int) "invalid cursor" 400
    (Router.handle router (request "GET" "/v1/jobs?cursor=nope")).status
let test_worker_protocol () =
  let router = router () in
  let worker_id = "00000000-0000-4000-8000-000000000099" in
  let registration = {|{"name":"local-worker","labels":[],"max_concurrency":1,"resources":{"cpu_millicores":1000,"memory_mib":512}}|} in
  Alcotest.(check int) "registered" 201
    (Router.handle router (request ~body:registration "PUT" ("/v1/workers/" ^ worker_id ^ "/registration"))).status;
  Alcotest.(check int) "registration update" 200
    (Router.handle router (request ~body:registration "PUT" ("/v1/workers/" ^ worker_id ^ "/registration"))).status;
  Alcotest.(check int) "heartbeat" 200
    (Router.handle router (request ~body:{|{"available_slots":1,"active_attempt_ids":[]}|} "POST"
      ("/v1/workers/" ^ worker_id ^ "/heartbeat"))).status;
  let created = Router.handle router (request ~body:valid_body "POST" "/v1/jobs") in
  let job_id = Yojson.Safe.from_string created.body |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  let poll = Router.handle router (request "POST" ("/v1/workers/" ^ worker_id ^ "/assignments/poll")) in
  Alcotest.(check int) "assigned" 200 poll.status;
  let attempt_id = Yojson.Safe.from_string poll.body |> Yojson.Safe.Util.member "attempt_id" |> Yojson.Safe.Util.to_string in
  Alcotest.(check int) "acknowledged" 200
    (Router.handle router (request "POST" ("/v1/attempts/" ^ attempt_id ^ "/acknowledge"))).status;
  Alcotest.(check int) "started" 200
    (Router.handle router (request "POST" ("/v1/attempts/" ^ attempt_id ^ "/started"))).status;
  Alcotest.(check int) "succeeded" 200
    (Router.handle router (request ~body:{|{"type":"succeeded","exit_code":0}|} "POST"
      ("/v1/attempts/" ^ attempt_id ^ "/result"))).status;
  let attempts = Router.handle router (request "GET" ("/v1/jobs/" ^ job_id ^ "/attempts")) in
  let status = Yojson.Safe.from_string attempts.body |> Yojson.Safe.Util.member "items"
    |> Yojson.Safe.Util.to_list |> List.hd |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "terminal status" "succeeded" status;
  Alcotest.(check int) "empty poll" 204
    (Router.handle router (request "POST" ("/v1/workers/" ^ worker_id ^ "/assignments/poll"))).status
let test_stop_confirmation () =
  let router,persistence = fixture () in
  let worker = "00000000-0000-4000-8000-000000000091"
  and wrong = "00000000-0000-4000-8000-000000000092"
  and attempt = "00000000-0000-4000-8000-000000000093" in
  let registration = {|{"name":"control-worker","labels":[],"max_concurrency":1,"resources":{"cpu_millicores":100,"memory_mib":100}}|} in
  ignore (Router.handle router (request ~body:registration "PUT" ("/v1/workers/" ^ worker ^ "/registration")));
  ignore (Router.handle router (request ~body:registration "PUT" ("/v1/workers/" ^ wrong ^ "/registration")));
  let worker_id = Orchestraml_domain.Identifiers.Worker_id.of_string worker |> get_ok
  and attempt_id = Orchestraml_domain.Identifiers.Attempt_id.of_string attempt |> get_ok in
  let created = persistence.Ports.Persistence.with_transaction (fun repositories ->
    repositories.controls.create_stop_unknown ~worker_id ~attempt_id ~requested_at:timestamp) in
  (match created with Ok (Ok true) -> () | _ -> Alcotest.fail "stop request not created");
  Alcotest.(check int) "wrong owner" 409 (Router.handle router
    (request "POST" ("/v1/workers/" ^ wrong ^ "/controls/" ^ attempt ^ "/stopped"))).status;
  Alcotest.(check int) "confirmed" 204 (Router.handle router
    (request "POST" ("/v1/workers/" ^ worker ^ "/controls/" ^ attempt ^ "/stopped"))).status;
  Alcotest.(check int) "repeated" 204 (Router.handle router
    (request "POST" ("/v1/workers/" ^ worker ^ "/controls/" ^ attempt ^ "/stopped"))).status;
  Alcotest.(check int) "invalid ID" 400 (Router.handle router
    (request "POST" ("/v1/workers/nope/controls/" ^ attempt ^ "/stopped"))).status
let () = Alcotest.run "orchestraml-coordinator" ["api",[
  Alcotest.test_case "submit and get" `Quick test_submit_and_get;
  Alcotest.test_case "idempotency and validation" `Quick test_idempotency_and_validation;
  Alcotest.test_case "health and missing" `Quick test_health_and_missing;
  Alcotest.test_case "pagination and query validation" `Quick test_pagination_validation;
  Alcotest.test_case "worker protocol lifecycle" `Quick test_worker_protocol;
  Alcotest.test_case "stop confirmation" `Quick test_stop_confirmation]]
