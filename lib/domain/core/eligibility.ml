open Foundation
open Shared

type rejection_reason = Worker_not_healthy of Worker_health.t
  | Missing_labels of Worker_label.Set.t | No_concurrency
  | Insufficient_cpu | Insufficient_memory
type t = Eligible | Ineligible of rejection_reason list
let evaluate ~health_policy ~now ~job ~worker =
  let reasons = ref [] in
  let health = Worker_health.classify health_policy ~now ~last_heartbeat:(Worker.last_heartbeat worker) in
  if not (Worker_health.equal health Worker_health.Healthy) then
    reasons := Worker_not_healthy health :: !reasons;
  let missing = Worker_label.Set.diff (Job.effective_required_labels job) (Worker.labels worker) in
  if not (Worker_label.Set.is_empty missing) then reasons := Missing_labels missing :: !reasons;
  if Worker.free_slots worker <= 0 then reasons := No_concurrency :: !reasons;
  let required = Job.requirements job and available = Worker.available_resources worker in
  if Scalar.Cpu_millicores.compare (Resources.cpu required) (Resources.cpu available) > 0 then
    reasons := Insufficient_cpu :: !reasons;
  if Scalar.Memory_mib.compare (Resources.memory required) (Resources.memory available) > 0 then
    reasons := Insufficient_memory :: !reasons;
  match List.rev !reasons with [] -> Eligible | reasons -> Ineligible reasons
let is_eligible = function Eligible -> true | Ineligible _ -> false
