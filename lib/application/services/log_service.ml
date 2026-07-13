open Orchestraml_domain
open Foundation
open Identifiers
open Shared
open Core
type error = Persistence_error of Ports.Persistence.error | Invalid_batch of string
  | Wrong_worker | Terminal_attempt
type follow_snapshot = { entries : Log_entry.t list; highest_sequence : int; terminal : bool }
type t = { persistence : Ports.Persistence.t; clock : Ports.Clock.t }
let create ~persistence ~clock = { persistence; clock }
let transact service callback = match service.persistence.with_transaction callback with
  | Error error | Ok (Error error) -> Error (Persistence_error error)
  | Ok (Ok value) -> Ok value
let validate entries =
  let rec loop previous bytes = function
    | [] -> if bytes > 65536 then Error "decoded batch exceeds 65536 bytes" else Ok ()
    | entry :: rest ->
        let current = Log_entry.(sequence_number entry |> sequence_value) in
        if current <= previous then Error "sequences must be strictly increasing"
        else loop current (bytes + String.length (Log_entry.payload entry)) rest in
  loop 0 0 entries
let append_batch service ~worker_id ~attempt_id entries = match validate entries with
  | Error message -> Error (Invalid_batch message)
  | Ok () ->
      let outcome = service.persistence.with_transaction (fun repositories ->
        match repositories.attempts.find_attempt attempt_id with
        | Error error -> Error error
        | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Attempt, Attempt_id.to_string attempt_id))
        | Ok (Some attempt) when not (Worker_id.equal worker_id (Attempt.worker_id attempt)) -> Ok `Wrong_worker
        | Ok (Some attempt) ->
            if List.exists (fun entry -> not (Attempt_id.equal attempt_id (Log_entry.attempt_id entry))) entries
            then Ok (`Invalid "entry attempt does not match request")
            else if Attempt_status.is_terminal (Attempt.status attempt) && entries <> [] then
              let first = List.hd entries |> Log_entry.sequence_number |> Log_entry.sequence_value in
              (match repositories.logs.list_logs ~attempt_id ~after_sequence:(first - 1) ~limit:(List.length entries) with
               | Error error -> Error error
               | Ok stored when List.length stored = List.length entries
                   && List.for_all2 Log_entry.equal stored entries ->
                   repositories.logs.append_log_batch ~attempt_id ~entries ~received_at:(service.clock.now ())
                   |> Result.map (fun value -> `Accepted value)
               | Ok _ -> Ok `Terminal)
            else repositories.logs.append_log_batch ~attempt_id ~entries ~received_at:(service.clock.now ())
              |> Result.map (fun value -> `Accepted value)) in
      match outcome with
      | Error error | Ok (Error error) -> Error (Persistence_error error)
      | Ok (Ok `Wrong_worker) -> Error Wrong_worker
      | Ok (Ok (`Invalid message)) -> Error (Invalid_batch message)
      | Ok (Ok `Terminal) -> Error Terminal_attempt
      | Ok (Ok (`Accepted value)) -> Ok value
let list service ~attempt_id ~after_sequence ~limit =
  if after_sequence < 0 then Error (Invalid_batch "after_sequence must be non-negative")
  else if limit < 1 || limit > 5000 then Error (Invalid_batch "limit must be between 1 and 5000")
  else transact service (fun repositories -> match repositories.attempts.find_attempt attempt_id with
    | Error error -> Error error
    | Ok None -> Error (Ports.Persistence.Not_found (Ports.Persistence.Attempt, Attempt_id.to_string attempt_id))
    | Ok (Some _) -> repositories.logs.list_logs ~attempt_id ~after_sequence ~limit)
let follow_snapshot service ~attempt_id ~after_sequence ~limit =
  match list service ~attempt_id ~after_sequence ~limit with Error _ as error -> error
  | Ok entries ->
      let highest_sequence = List.fold_left (fun current entry ->
        max current Log_entry.(sequence_number entry |> sequence_value)) after_sequence entries in
      match transact service (fun repositories -> repositories.attempts.find_attempt attempt_id) with
      | Error _ as error -> error
      | Ok None -> Error (Persistence_error (Ports.Persistence.Not_found
          (Ports.Persistence.Attempt, Attempt_id.to_string attempt_id)))
      | Ok (Some attempt) -> Ok { entries; highest_sequence;
          terminal = Attempt_status.is_terminal (Attempt.status attempt) }
