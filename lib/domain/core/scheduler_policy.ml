open Foundation
open Identifiers
open Shared

let compare_jobs left right =
  let by_priority = Scalar.Priority.compare (Job.priority right) (Job.priority left) in
  if by_priority <> 0 then by_priority
  else let by_time = Timestamp.compare (Job.created_at left) (Job.created_at right) in
    if by_time <> 0 then by_time else Job_id.compare (Job.id left) (Job.id right)

let first = function [] -> None | value :: _ -> Some value

let select_job jobs =
  jobs |> List.filter (fun job -> Job_status.equal (Job.status job) Job_status.Pending)
       |> List.sort compare_jobs |> first

let compare_ratio left_active left_max right_active right_max =
  Int64.compare
    (Int64.mul (Int64.of_int left_active) (Int64.of_int right_max))
    (Int64.mul (Int64.of_int right_active) (Int64.of_int left_max))

let compare_workers left right =
  let by_load = compare_ratio (Worker.active_jobs left)
      (Scalar.Concurrency.value (Worker.max_concurrency left))
      (Worker.active_jobs right) (Scalar.Concurrency.value (Worker.max_concurrency right)) in
  if by_load <> 0 then by_load
  else
    let left_free = Worker.available_resources left and right_free = Worker.available_resources right in
    let by_cpu = Scalar.Cpu_millicores.compare (Resources.cpu right_free) (Resources.cpu left_free) in
    if by_cpu <> 0 then by_cpu
    else let by_memory = Scalar.Memory_mib.compare (Resources.memory right_free) (Resources.memory left_free) in
      if by_memory <> 0 then by_memory else Worker_id.compare (Worker.id left) (Worker.id right)

let select_worker ~health_policy ~now ~job workers =
  workers
  |> List.filter (fun worker -> Eligibility.evaluate ~health_policy ~now ~job ~worker |> Eligibility.is_eligible)
  |> List.sort compare_workers
  |> first
