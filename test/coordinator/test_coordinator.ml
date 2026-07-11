open Orchestraml_application
module Support = Orchestraml_test_support
module Router = Orchestraml_coordinator.Api.Router
let get_ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture error"
let timestamp = Orchestraml_domain.Foundation.Timestamp.of_rfc3339 "2026-01-01T00:00:00Z" |> get_ok
let router () =
  let persistence = Memory.Persistence.create () in
  let clock = Support.Controlled_clock.create timestamp |> Support.Controlled_clock.port in
  let ids = Support.Deterministic_ids.create () |> Support.Deterministic_ids.port in
  let jobs = Services.Job_service.create ~persistence ~clock ~ids in
  Router.create ~jobs ~health:(fun () -> true)
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
let () = Alcotest.run "orchestraml-coordinator" ["api",[
  Alcotest.test_case "submit and get" `Quick test_submit_and_get;
  Alcotest.test_case "idempotency and validation" `Quick test_idempotency_and_validation;
  Alcotest.test_case "health and missing" `Quick test_health_and_missing;
  Alcotest.test_case "pagination and query validation" `Quick test_pagination_validation]]
