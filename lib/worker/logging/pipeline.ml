open Orchestraml_domain
open Foundation
open Identifiers
open Shared
module Coordinator = Client.Coordinator
type t = { sw:Eio.Switch.t; sleep:float -> unit; client:Coordinator.t;
  worker_id:Worker_id.t; attempt_id:Attempt_id.t; batch_bytes:int; pending_limit:int;
  flush_interval:float; mutable next:int; mutable pending:Log_entry.t list;
  mutable pending_bytes:int; mutable closed:bool; mutex:Eio.Mutex.t }
let now () = Ptime_clock.now () |> Timestamp.of_ptime
let create ~sw ~clock ~client ~worker_id ~attempt_id ~batch_bytes ~pending_limit ~flush_interval =
  let value = { sw; sleep=(Eio.Time.sleep clock); client; worker_id; attempt_id; batch_bytes; pending_limit;
    flush_interval; next=1; pending=[]; pending_bytes=0; closed=false; mutex=Eio.Mutex.create () } in
  Eio.Fiber.fork ~sw (fun () -> while not value.closed do Eio.Time.sleep clock flush_interval;
    Eio.Mutex.use_rw ~protect:false value.mutex (fun () ->
      if value.pending <> [] then match Coordinator.upload_logs ~sw value.client
          ~worker_id ~attempt_id value.pending with
        | Ok _ -> value.pending <- []; value.pending_bytes <- 0
        | Error _ -> ()) done);
  value
let flush_unlocked value = match value.pending with [] -> Ok () | entries ->
  match Coordinator.upload_logs ~sw:value.sw value.client ~worker_id:value.worker_id
    ~attempt_id:value.attempt_id entries with
  | Ok _ -> value.pending <- []; value.pending_bytes <- 0; Ok ()
  | Error error -> Error error
let rec ensure_capacity_unlocked value bytes =
  if value.pending_bytes + bytes <= value.pending_limit then ()
  else match flush_unlocked value with
    | Ok () -> ()
    | Error error when Coordinator.retryable error -> value.sleep value.flush_interval;
        ensure_capacity_unlocked value bytes
    | Error _ -> failwith "permanent log upload rejection"
let rec flush_required value = match flush_unlocked value with
  | Ok () -> ()
  | Error error when Coordinator.retryable error -> value.sleep value.flush_interval; flush_required value
  | Error _ -> failwith "permanent log upload rejection"
let add value stream payload =
  Eio.Mutex.use_rw ~protect:false value.mutex (fun () ->
    ensure_capacity_unlocked value (String.length payload);
    if value.pending <> [] && value.pending_bytes + String.length payload > value.batch_bytes then
      flush_required value;
    let sequence = Log_entry.sequence value.next |> Result.get_ok in
    let entry = Log_entry.create ~attempt_id:value.attempt_id ~sequence ~stream
      ~observed_at:(now ()) ~payload |> Result.get_ok in
    value.next <- value.next + 1; value.pending <- value.pending @ [entry];
    value.pending_bytes <- value.pending_bytes + String.length payload;
    if value.pending_bytes >= value.batch_bytes then ignore (flush_unlocked value))
let emit value stream payload =
  let rec chunks offset =
    if offset < String.length payload then let length = min (16*1024) (String.length payload - offset) in
      add value stream (String.sub payload offset length); chunks (offset + length) in
  chunks 0
let rec flush_retry_unlocked value = match flush_unlocked value with Ok () -> Ok ()
  | Error error when Coordinator.retryable error -> value.sleep value.flush_interval; flush_retry value
  | Error error -> Error error
and flush_retry value = flush_retry_unlocked value
let close_and_flush value = value.closed <- true;
  Eio.Mutex.use_rw ~protect:false value.mutex (fun () -> flush_retry_unlocked value)
