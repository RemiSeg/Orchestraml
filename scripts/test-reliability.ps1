$ErrorActionPreference = "Stop"
$image = "orchestraml-dev:phase5"
$coordinator = "orchestraml-reliability-coordinator"
$workerA = "orchestraml-reliability-worker-a"
$workerB = "orchestraml-reliability-worker-b"
$identityA = "orchestraml-reliability-identity-a"
$identityB = "orchestraml-reliability-identity-b"
$faultVolume = "orchestraml-reliability-fault"
$base = "http://127.0.0.1:18081"

function Remove-Container([string]$name) {
  if (docker ps -aq --filter "name=^/${name}$") { docker rm -f $name | Out-Null }
}
function Logs-On-Failure {
  $oldPreference=$ErrorActionPreference; $ErrorActionPreference="Continue"
  foreach ($name in @($coordinator,$workerA,$workerB)) {
    if (docker ps -aq --filter "name=^/${name}$") {
      Write-Host "===== $name ====="; docker logs $name 2>&1
    }
  }
  $ErrorActionPreference=$oldPreference
}
function Wait-Until([scriptblock]$condition,[string]$description,[int]$seconds=20) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    try { $value = & $condition; if ($null -ne $value -and $value -ne $false) { return $value } } catch {}
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for $description"
}
function Start-Coordinator {
  Remove-Container $coordinator
  docker run -d --name $coordinator --network orchestraml_default -p 18081:8080 `
    -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    -e LISTEN_ADDRESS=0.0.0.0 -e PORT=8080 `
    -e SCHEDULER_INTERVAL_SECONDS=0.2 -e RETRY_INTERVAL_SECONDS=0.2 `
    -e MAINTENANCE_INTERVAL_SECONDS=0.2 -e WORKER_SUSPECT_AFTER_SECONDS=2 `
    -e WORKER_OFFLINE_AFTER_SECONDS=4 -e ASSIGNMENT_ACK_TIMEOUT_SECONDS=2 `
    -e EXECUTION_REPORT_GRACE_SECONDS=1 -e HEARTBEAT_RECOVERY_GRACE_SECONDS=2 `
    -e MAINTENANCE_BATCH_SIZE=2 -e STARTUP_RECONCILIATION_MAX_PASSES=100 `
    $image opam exec -- dune exec orchestraml-coordinator -- serve | Out-Null
  Wait-Until { try { if ((Invoke-WebRequest -UseBasicParsing "$base/health" -TimeoutSec 1).StatusCode -eq 200) { return $true } } catch {} } "coordinator health" | Out-Null
}
function Start-Worker([string]$name,[string]$identity,[string]$label) {
  Remove-Container $name
  docker volume create $identity | Out-Null
  docker run --rm --user root -v "${identity}:/var/lib/orchestraml" $image chown -R opam:opam /var/lib/orchestraml
  docker run -d --name $name --network orchestraml_default `
    -e COORDINATOR_URL=http://${coordinator}:8080 -e WORKER_NAME=$name -e WORKER_LABELS=$label `
    -e WORKER_MAX_CONCURRENCY=1 -e WORKER_CPU_MILLICORES=1000 -e WORKER_MEMORY_MIB=512 `
    -e HEARTBEAT_INTERVAL_SECONDS=0.5 -e POLL_INTERVAL_SECONDS=0.2 `
    -e CONTROL_POLL_INTERVAL_SECONDS=0.2 -e TERMINATION_GRACE_SECONDS=1 `
    -v "${identity}:/var/lib/orchestraml" -v "${faultVolume}:/fault" `
    $image opam exec -- dune exec orchestraml-worker | Out-Null
  Wait-Until { $items=@((Invoke-RestMethod "$base/v1/workers").items)|?{$_.name -eq $name}; if($items){$items[0]} } "worker $name registration" | Out-Null
}
function Submit-Job([string]$name,[string]$executable,[object[]]$arguments,[int]$timeout,[int]$attempts,[bool]$retryTimeouts,[string]$label) {
  $body = @{ name=$name; execution=@{type="command";executable=$executable;arguments=$arguments};
    timeout_seconds=$timeout; max_attempts=$attempts; retry=@{initial_delay_seconds=1;multiplier=1;maximum_delay_seconds=1;retry_timeouts=$retryTimeouts};
    required_labels=@($label); resources=@{cpu_millicores=10;memory_mib=10} } | ConvertTo-Json -Depth 8 -Compress
  Invoke-RestMethod "$base/v1/jobs" -Method Post -ContentType application/json -Body $body
}
function Wait-Job([string]$id,[string[]]$statuses,[int]$seconds=20) {
  try { Wait-Until { $job=Invoke-RestMethod "$base/v1/jobs/$id"; if($statuses -contains $job.status){$job} } "job $id status $($statuses -join ',')" $seconds }
  catch { Write-Host (Invoke-RestMethod "$base/v1/jobs/$id" | ConvertTo-Json -Depth 8);
    Write-Host ((Attempts $id) | ConvertTo-Json -Depth 8); throw }
}
function Attempts([string]$id) { @((Invoke-RestMethod "$base/v1/jobs/$id/attempts").items) }
function Assert-ZeroCapacity([string]$workerId) {
  $worker=Invoke-RestMethod "$base/v1/workers/$workerId"
  if($worker.active_jobs -ne 0 -or $worker.resources.reserved_cpu_millicores -ne 0 -or $worker.resources.reserved_memory_mib -ne 0){throw "capacity leaked for $workerId"}
}

Remove-Container $workerA; Remove-Container $workerB; Remove-Container $coordinator
docker compose down --volumes
foreach($volume in @($identityA,$identityB,$faultVolume)){docker volume rm -f $volume 2>$null | Out-Null}
docker compose up -d --wait postgres
try {
  docker build -q -f Dockerfile.dev -t $image . | Out-Null
  docker run --rm --network orchestraml_default -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    $image opam exec -- dune exec orchestraml-coordinator -- migrate
  Start-Coordinator

  # Crash before acknowledgement: a registered phantom worker disappears after assignment.
  $phantomId="00000000-0000-4000-8000-000000000071"
  $registration=@{name="phantom";labels=@("phantom");max_concurrency=1;resources=@{cpu_millicores=1000;memory_mib=512}}|ConvertTo-Json -Depth 5 -Compress
  Invoke-RestMethod "$base/v1/workers/$phantomId/registration" -Method Put -ContentType application/json -Body $registration | Out-Null
  $job=Submit-Job "pre-ack-crash" "/bin/true" @() 30 2 $false "phantom"
  $phantomAssignment=Invoke-RestMethod "$base/v1/workers/$phantomId/assignments/poll" -Method Post
  Wait-Until { $a=@(Attempts $job.id); if($a.Count -ge 1 -and $a[0].status -eq "lost"){$a[0]} } "assignment timeout loss" 20 | Out-Null
  Assert-ZeroCapacity $phantomId
  $attempt=(@(Attempts $job.id))[0]
  try { Invoke-WebRequest -UseBasicParsing "$base/v1/attempts/$($attempt.id)/acknowledge" -Method Post | Out-Null; throw "late acknowledgement succeeded" }
  catch { if($_.Exception.Response.StatusCode.value__ -ne 409){throw} }

  docker volume create $faultVolume | Out-Null
  docker run --rm --user root -v "${faultVolume}:/fault" $image chown -R opam:opam /fault
  Start-Worker $workerA $identityA "crash"
  $workerARecord=Wait-Until { $x=@((Invoke-RestMethod "$base/v1/workers").items)|?{$_.name -eq $workerA};if($x){$x[0]} } "worker A"
  $command="if [ -f /fault/once ]; then exit 0; else touch /fault/once; sleep 60; fi"
  $job=Submit-Job "running-crash" "/bin/sh" @("-c",$command) 120 2 $false "crash"
  Wait-Job $job.id @("running") | Out-Null
  Remove-Container $workerA
  Wait-Until { $a=@(Attempts $job.id);if($a.Count -ge 1 -and $a[0].status -eq "lost"){$a[0]} } "running worker loss" 20 | Out-Null
  Assert-ZeroCapacity $workerARecord.id
  docker run --rm --user root -v "${faultVolume}:/fault" $image touch /fault/once
  Start-Worker $workerB $identityB "crash"
  Wait-Job $job.id @("completed") 15 | Out-Null
  $history=Attempts $job.id
  if($history.Count -ne 2 -or $history[0].status -ne "lost" -or $history[1].status -ne "succeeded"){throw "invalid crash retry history"}

  # Reuse worker B for cancellation and both timeout modes.
  $cancel=Submit-Job "running-cancel" "/bin/sleep" @("60") 120 1 $false "crash"
  Wait-Job $cancel.id @("running") | Out-Null
  Invoke-RestMethod "$base/v1/jobs/$($cancel.id)/cancel" -Method Post | Out-Null
  Wait-Job $cancel.id @("cancelled") 12 | Out-Null
  $workerBRecord=Invoke-RestMethod "$base/v1/workers/$($history[1].worker_id)"
  Assert-ZeroCapacity $workerBRecord.id

  $graceful=Submit-Job "graceful-timeout" "/bin/sleep" @("60") 1 1 $false "crash"
  Wait-Job $graceful.id @("permanently_failed") 12 | Out-Null
  if((Attempts $graceful.id)[0].status -ne "timed_out"){throw "graceful timeout was not persisted"}

  $stubborn="/workspace/_build/default/test/fault/stubborn_process.exe"
  $forced=Submit-Job "forced-timeout" $stubborn @() 1 1 $false "crash"
  Wait-Job $forced.id @("permanently_failed") 12 | Out-Null
  $oldPreference=$ErrorActionPreference; $ErrorActionPreference="Continue"
  $workerLogs=(docker logs $workerB 2>&1 | Out-String); $ErrorActionPreference=$oldPreference
  if(-not ($workerLogs -match "attempt $((Attempts $forced.id)[0].id) termination=force_killed")){throw "forced-kill diagnostic missing"}
  $probe=Submit-Job "slot-probe" "/bin/true" @() 30 1 $false "crash"
  Wait-Job $probe.id @("completed") 10 | Out-Null
  Assert-ZeroCapacity $workerBRecord.id

  # Unknown attempt controls are durable and survive coordinator restart.
  $unknown="00000000-0000-4000-8000-000000000099"
  $unknownWorker="00000000-0000-4000-8000-000000000072"
  $unknownRegistration=@{name="unknown-reporter";labels=@("unknown");max_concurrency=1;resources=@{cpu_millicores=1000;memory_mib=512}}|ConvertTo-Json -Depth 5 -Compress
  Invoke-RestMethod "$base/v1/workers/$unknownWorker/registration" -Method Put -ContentType application/json -Body $unknownRegistration | Out-Null
  $heartbeat=@{available_slots=1;active_attempt_ids=@($unknown)}|ConvertTo-Json -Compress
  Invoke-RestMethod "$base/v1/workers/$unknownWorker/heartbeat" -Method Post -ContentType application/json -Body $heartbeat | Out-Null
  $control=Wait-Until { try{$r=Invoke-RestMethod "$base/v1/workers/$unknownWorker/controls/poll" -Method Post;@($r.items)|?{$_.attempt_id -eq $unknown}}catch{} } "stop-unknown control"
  Remove-Container $coordinator; Start-Coordinator
  $redelivered=Wait-Until { try{$r=Invoke-RestMethod "$base/v1/workers/$unknownWorker/controls/poll" -Method Post;@($r.items)|?{$_.attempt_id -eq $unknown}}catch{} } "redelivered stop control"
  Invoke-WebRequest -UseBasicParsing "$base/v1/workers/$unknownWorker/controls/$unknown/stopped" -Method Post | Out-Null
  $empty=Invoke-WebRequest -UseBasicParsing "$base/v1/workers/$unknownWorker/controls/poll" -Method Post
  if($empty.StatusCode -ne 204){throw "completed stop control was redelivered"}
}
catch { Logs-On-Failure; throw }
finally {
  Remove-Container $workerA; Remove-Container $workerB; Remove-Container $coordinator
  foreach($volume in @($identityA,$identityB,$faultVolume)){docker volume rm -f $volume 2>$null | Out-Null}
  docker compose down --volumes
}
