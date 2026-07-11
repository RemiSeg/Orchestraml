module Services = Orchestraml_application.Services
type error = Start_error of Services.Execution_service.error
  | Report_error of Services.Execution_service.error | Executor_exhausted of string
let run ~execution_service ~executor (assignment : Services.Scheduling_service.assignment) =
  let attempt_id = Orchestraml_domain.Core.Attempt.id assignment.attempt in
  match Services.Execution_service.start_attempt execution_service attempt_id with
  | Error error -> Error (Start_error error)
  | Ok _ -> match Scripted_executor.next executor with
      | Error error -> Error (Executor_exhausted error)
      | Ok outcome ->
          let report = match outcome with
            | Scripted_executor.Succeeded exit_code ->
                Services.Execution_service.report_success execution_service attempt_id ~exit_code
            | Scripted_executor.Failed failure ->
                Services.Execution_service.report_failure execution_service attempt_id ~failure
            | Scripted_executor.Timed_out ->
                Services.Execution_service.report_timeout execution_service attempt_id
            | Scripted_executor.Lost reason ->
                Services.Execution_service.report_lost execution_service attempt_id ~reason
            | Scripted_executor.Cancelled ->
                Services.Execution_service.report_cancelled execution_service attempt_id in
          match report with Ok completed -> Ok completed | Error error -> Error (Report_error error)
