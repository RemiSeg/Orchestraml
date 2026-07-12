open Orchestraml_domain
open Shared
module Executor = Orchestraml_worker.Executor.Local_process
module Identity = Orchestraml_worker.Runtime.Identity
let get_ok = function Ok value -> value | Error message -> Alcotest.fail message
let command executable arguments = Execution_spec.command ~executable ~arguments |> Result.get_ok
let run specification = Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  match Executor.start ~sw ~process_mgr:env#process_mgr specification with
  | Error failure -> `Start_failure failure
  | Ok process -> `Outcome (Executor.await process)
let failure_kind = function
  | `Start_failure failure | `Outcome (Executor.Failed failure) -> Failure.kind failure
  | `Outcome (Executor.Succeeded _) -> Alcotest.fail "expected failure"
let test_process_outcomes () =
  (match run (command "/bin/true" []) with
   | `Outcome (Executor.Succeeded 0) -> () | _ -> Alcotest.fail "true did not succeed");
  Alcotest.(check bool) "false is temporary execution failure" true
    (failure_kind (run (command "/bin/false" [])) = Failure.Temporary_execution_failure);
  Alcotest.(check bool) "missing executable" true
    (failure_kind (run (command "/definitely/missing/orchestraml" [])) = Failure.Missing_executable);
  Alcotest.(check bool) "permission denied" true
    (failure_kind (run (command "/etc/passwd" [])) = Failure.Permission_denied);
  let container = Execution_spec.container ~image:"example:latest" ~command:[] |> Result.get_ok in
  Alcotest.(check bool) "container unsupported" true
    (failure_kind (run container) = Failure.Invalid_configuration)
let test_no_implicit_shell_and_bounded_output () =
  (match run (command "/usr/bin/test" ["$HOME"; "="; "/home/opam"]) with
   | `Outcome (Executor.Failed _) -> ()
   | _ -> Alcotest.fail "arguments were unexpectedly shell-expanded");
  match run (command "/bin/sh" ["-c"; "head -c 100000 /dev/zero >&2; exit 1"]) with
  | `Outcome (Executor.Failed failure) ->
      let length = Failure.message failure |> Option.value ~default:"" |> String.length in
      Alcotest.(check bool) "diagnostic tail bounded" true (length <= 66_000)
  | _ -> Alcotest.fail "large-output command did not fail as expected"
let test_stable_identity () =
  let root = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "orchestraml-identity-%d" (Unix.getpid ())) in
  let path = Filename.concat root "nested/worker-id" in
  let first = Identity.load_or_create path |> get_ok in
  let second = Identity.load_or_create path |> get_ok in
  Alcotest.(check bool) "identity stable" true
    (Identifiers.Worker_id.equal first second)
let test_termination_modes () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  let start spec = Executor.start ~sw ~process_mgr:env#process_mgr spec |> function
    | Ok value -> value | Error _ -> Alcotest.fail "process did not start" in
  let graceful = start (command "/bin/sleep" ["60"]) in
  Alcotest.(check bool) "graceful" true
    (Executor.stop ~clock:env#clock ~grace:1. graceful = Executor.Exited_during_grace);
  Alcotest.(check bool) "repeated stop" true
    (Executor.stop ~clock:env#clock ~grace:0.1 graceful = Executor.Already_exited);
  let stubborn = start (command "/workspace/_build/default/test/fault/stubborn_process.exe" []) in
  Eio.Time.sleep env#clock 0.1;
  Alcotest.(check bool) "forced" true
    (Executor.stop ~clock:env#clock ~grace:0.1 stubborn = Executor.Force_killed)
let () = Alcotest.run "orchestraml-worker" [
  "executor", [
    Alcotest.test_case "process outcomes" `Quick test_process_outcomes;
    Alcotest.test_case "no shell and bounded output" `Quick test_no_implicit_shell_and_bounded_output;
    Alcotest.test_case "termination modes" `Quick test_termination_modes];
  "identity", [Alcotest.test_case "stable nested identity" `Quick test_stable_identity]]
