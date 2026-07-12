open Orchestraml_domain
open Identifiers
module Coordinator = Client.Coordinator

type control = { mutable stopped : bool }
type requested = No_control | Cancel | Timeout | Stop_unknown
type active = { running : Executor.Local_process.running; mutable requested : requested;
  mutable force_killed : bool }

let create_control () = { stopped = false }
let stop value = value.stopped <- true
let log_error context error = Format.eprintf "%s: %a@." context Coordinator.pp_error error
let rec retry ~control ~clock ~delay operation =
  if control.stopped then Error `Stopped
  else match operation () with
    | Ok value -> Ok value
    | Error error when Coordinator.retryable error ->
        log_error "temporary coordinator request failure" error;
        Eio.Time.sleep clock delay; retry ~control ~clock ~delay operation
    | Error error -> Error (`Permanent error)

let stop_process ~clock ~grace active =
  let termination = Executor.Local_process.stop ~clock ~grace active.running in
  active.force_killed <- termination = Executor.Local_process.Force_killed;
  Executor.Local_process.await active.running
let log_termination id state =
  let result = if state.force_killed then "force_killed"
    else if Executor.Local_process.is_finished state.running then "exited_during_grace"
    else "already_exited" in
  Format.eprintf "attempt %s termination=%s@." (Attempt_id.to_string id) result

let run_assignment ~control ~clock ~delay ~sw ~process_mgr ~client ~worker_id active_count active_ids active assignment =
  active_ids := assignment.Coordinator.attempt_id :: !active_ids;
  Fun.protect ~finally:(fun () ->
    active_count := !active_count - 1;
    Hashtbl.remove active assignment.attempt_id;
    active_ids := List.filter (fun id -> not (Attempt_id.equal id assignment.attempt_id)) !active_ids)
    (fun () ->
      match retry ~control ~clock ~delay (fun () -> Coordinator.acknowledge ~sw client assignment.attempt_id) with
      | Error (`Permanent error) -> log_error "assignment acknowledgement rejected" error
      | Error `Stopped -> ()
      | Ok () ->
          match Executor.Local_process.start ~sw ~process_mgr assignment.execution with
          | Error failure -> ignore (retry ~control ~clock ~delay (fun () ->
              Coordinator.report ~sw client assignment.attempt_id (Coordinator.Failed failure)))
          | Ok running ->
              let state = { running; requested = No_control; force_killed = false } in
              Hashtbl.replace active assignment.attempt_id state;
              (match retry ~control ~clock ~delay (fun () -> Coordinator.started ~sw client assignment.attempt_id) with
               | Error _ -> Executor.Local_process.terminate running; ignore (Executor.Local_process.await running)
               | Ok () ->
                   let timeout = Foundation.Scalar.Timeout_seconds.value assignment.timeout |> float_of_int in
                   let outcome = try `Finished (Eio.Time.with_timeout_exn clock timeout
                       (fun () -> Executor.Local_process.await running))
                     with Eio.Time.Timeout -> state.requested <- Timeout;
                       `Finished (stop_process ~clock ~grace:delay state) in
                   if state.requested <> No_control then log_termination assignment.attempt_id state;
                   let report = match state.requested, outcome with
                     | Cancel, _ -> Coordinator.Cancelled
                     | Timeout, _ -> Coordinator.Timed_out
                     | Stop_unknown, _ -> Coordinator.Cancelled
                     | No_control, `Finished (Executor.Local_process.Succeeded code) -> Coordinator.Succeeded code
                     | No_control, `Finished (Executor.Local_process.Failed failure) -> Coordinator.Failed failure in
                   (match state.requested with
                    | Stop_unknown -> ignore (retry ~control ~clock ~delay (fun () ->
                        Coordinator.confirm_stopped ~sw client ~worker_id assignment.attempt_id))
                    | _ -> ignore (retry ~control ~clock ~delay (fun () ->
                        Coordinator.report ~sw client assignment.attempt_id report)))))

let request_stop ~sw ~clock ~grace state requested =
  if state.requested = No_control then begin
    state.requested <- requested;
    Executor.Local_process.terminate state.running;
    Eio.Fiber.fork ~sw (fun () -> Eio.Time.sleep clock grace;
      if not (Executor.Local_process.is_finished state.running) then begin
        state.force_killed <- true; Executor.Local_process.kill state.running
      end)
  end
let apply_control ~sw ~clock ~grace active = function
  | Coordinator.Cancel id ->
      (match Hashtbl.find_opt active id with None -> () | Some state ->
        request_stop ~sw ~clock ~grace state Cancel)
  | Coordinator.Execution_timeout id ->
      (match Hashtbl.find_opt active id with None -> () | Some state ->
        request_stop ~sw ~clock ~grace state Timeout)
  | Coordinator.Stop_unknown id ->
      (match Hashtbl.find_opt active id with None -> () | Some state ->
        request_stop ~sw ~clock ~grace state Stop_unknown)

let run ~control ~sw ~clock ~process_mgr ~config ~worker_id ~client =
  let maximum = Foundation.Scalar.Concurrency.value config.Runtime.Config.max_concurrency in
  let active_count = ref 0 and active_ids = ref [] and active = Hashtbl.create maximum in
  let registration : Coordinator.registration = { worker_id; name = config.name;
    labels = config.labels; max_concurrency = config.max_concurrency; resources = config.resources } in
  (match retry ~control ~clock ~delay:config.poll_interval (fun () -> Coordinator.register ~sw client registration) with
   | Ok () -> () | Error `Stopped -> ()
   | Error (`Permanent error) -> log_error "worker registration rejected" error; stop control);
  Eio.Fiber.fork ~sw (fun () ->
    while not control.stopped do
      (match Coordinator.heartbeat ~sw client ~worker_id
        ~available_slots:(maximum - !active_count) ~active_attempt_ids:!active_ids with
       | Ok () -> () | Error error -> log_error "heartbeat failed" error);
      Eio.Time.sleep clock config.heartbeat_interval
    done);
  Eio.Fiber.fork ~sw (fun () ->
    while not control.stopped do
      (match Coordinator.poll_controls ~sw client worker_id with
       | Ok controls -> List.iter (fun request ->
           apply_control ~sw ~clock ~grace:config.termination_grace active request;
           match request with Coordinator.Stop_unknown id ->
             if not (Hashtbl.mem active id) then
               ignore (retry ~control ~clock ~delay:config.control_poll_interval (fun () ->
                 Coordinator.confirm_stopped ~sw client ~worker_id id)) | _ -> ()) controls
       | Error error -> log_error "control poll failed" error);
      Eio.Time.sleep clock config.control_poll_interval
    done);
  while not control.stopped do
    if !active_count < maximum then
      match Coordinator.poll ~sw client worker_id with
      | Ok (Some assignment) ->
          active_count := !active_count + 1;
          Eio.Fiber.fork ~sw (fun () -> run_assignment ~control ~clock
            ~delay:config.termination_grace ~sw ~process_mgr ~client ~worker_id active_count active_ids active assignment)
      | Ok None -> Eio.Time.sleep clock config.poll_interval
      | Error error -> log_error "assignment poll failed" error; Eio.Time.sleep clock config.poll_interval
    else Eio.Time.sleep clock config.poll_interval
  done
