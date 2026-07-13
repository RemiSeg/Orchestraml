$ErrorActionPreference = "Stop"
$image = "orchestraml-dev:phase6"
$coordinator = "orchestraml-phase6-coordinator"
$worker = "orchestraml-phase6-worker"
$identity = "orchestraml-phase6-identity"
$base = "http://127.0.0.1:18082"

function Remove-Container([string]$name) {
  if (docker ps -aq --filter "name=^/${name}$") { docker rm -f $name | Out-Null }
}
function Wait-Until([scriptblock]$condition, [string]$description, [int]$seconds = 60) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    try { $value = & $condition; if ($null -ne $value -and $value -ne $false) { return $value } } catch {}
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for $description"
}
function Logs-On-Failure {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  foreach ($name in @($coordinator, $worker)) {
    if (docker ps -aq --filter "name=^/${name}$") { Write-Host "===== $name ====="; docker logs $name 2>&1 }
  }
  docker ps -a --filter "label=orchestraml.managed=true"
  try { Invoke-RestMethod "$base/v1/workers" | ConvertTo-Json -Depth 6 | Write-Host } catch {}
  $ErrorActionPreference = $old
}

Remove-Container $worker
Remove-Container $coordinator
if (docker volume ls -q --filter "name=^${identity}$") { docker volume rm -f $identity | Out-Null }
docker compose down --volumes | Out-Null
try {
  docker compose up -d --wait postgres | Out-Null
  docker build -q -f Dockerfile.dev -t $image .
  docker run --rm --network orchestraml_default `
    -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    $image opam exec -- dune exec orchestraml-coordinator -- migrate
  if ($LASTEXITCODE -ne 0) { throw "Migration failed" }

  docker run -d --name $coordinator --network orchestraml_default -p 18082:8080 `
    -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    -e LISTEN_ADDRESS=0.0.0.0 -e PORT=8080 -e SCHEDULER_INTERVAL_SECONDS=0.2 `
    -e RETRY_INTERVAL_SECONDS=0.2 -e MAINTENANCE_INTERVAL_SECONDS=0.5 `
    $image opam exec -- dune exec orchestraml-coordinator -- serve | Out-Null
  Wait-Until { try { if ((Invoke-WebRequest -UseBasicParsing "$base/health" -TimeoutSec 2).StatusCode -eq 200) { return $true } } catch {} } "coordinator health" | Out-Null

  docker volume create $identity | Out-Null
  docker run --rm --user root -v "${identity}:/var/lib/orchestraml" $image chown -R opam:opam /var/lib/orchestraml
  docker run -d --name $worker --network orchestraml_default --group-add 0 `
    -e COORDINATOR_URL=http://${coordinator}:8080 -e WORKER_NAME=docker-worker `
    -e WORKER_LABELS=linux -e WORKER_MAX_CONCURRENCY=1 `
    -e WORKER_CPU_MILLICORES=1000 -e WORKER_MEMORY_MIB=512 `
    -e HEARTBEAT_INTERVAL_SECONDS=0.5 -e POLL_INTERVAL_SECONDS=0.2 `
    -e CONTROL_POLL_INTERVAL_SECONDS=0.2 -v "${identity}:/var/lib/orchestraml" `
    -v /var/run/docker.sock:/var/run/docker.sock `
    $image opam exec -- dune exec orchestraml-worker | Out-Null

  $registered = Wait-Until {
    $items = (Invoke-RestMethod "$base/v1/workers").items
    if (@($items).Count -eq 1 -and @($items[0].labels) -contains "docker") { return $items[0] }
  } "Docker-capable worker registration"

  $body = @{
    name = "container-logs"
    execution = @{ type = "container"; image = "alpine:3.21"; command = @("/bin/sh", "-c", "echo stdout-line; echo stderr-line 1>&2") }
    timeout_seconds = 30
    max_attempts = 1
    retry = @{ initial_delay_seconds = 1; multiplier = 2; maximum_delay_seconds = 5; retry_timeouts = $false }
    resources = @{ cpu_millicores = 250; memory_mib = 64 }
  } | ConvertTo-Json -Depth 5
  $job = Invoke-RestMethod "$base/v1/jobs" -Method Post -ContentType application/json -Body $body
  Wait-Until { $current = Invoke-RestMethod "$base/v1/jobs/$($job.id)"; if ($current.status -eq "completed") { return $current } } "container completion" | Out-Null
  $attempt = (Invoke-RestMethod "$base/v1/jobs/$($job.id)/attempts").items[0]
  $metadata = Invoke-RestMethod "$base/v1/attempts/$($attempt.id)/container"
  if ($metadata.cleanup_outcome -ne "removed" -or -not $metadata.started_at -or
      -not $metadata.finished_at -or -not $metadata.removed_at) {
    throw "Container lifecycle metadata is incomplete"
  }
  if ($metadata.image_reference -ne "alpine:3.21" -or $metadata.worker_id -ne $registered.id) {
    throw "Container metadata identity does not match the assignment"
  }
  $logs = Invoke-RestMethod "$base/v1/attempts/$($attempt.id)/logs?after_sequence=0&limit=1000"
  if (@($logs.items).Count -lt 2) { throw "Expected stdout and stderr log entries" }
  $streams = @($logs.items | ForEach-Object { $_.stream })
  if ($streams -notcontains "stdout" -or $streams -notcontains "stderr") { throw "Both output streams were not stored" }
  $follow = Invoke-WebRequest -UseBasicParsing "$base/v1/attempts/$($attempt.id)/logs/follow?after_sequence=0" -TimeoutSec 10
  if ($follow.Headers["Content-Type"] -notmatch "text/event-stream" -or $follow.Content -notmatch "id: 1") {
    throw "SSE did not replay stored logs"
  }
  $last = ($logs.items | Measure-Object -Property sequence -Maximum).Maximum
  $reconnected = Invoke-WebRequest -UseBasicParsing "$base/v1/attempts/$($attempt.id)/logs/follow" `
    -Headers @{ "Last-Event-ID" = "$last" } -TimeoutSec 10
  if ($reconnected.Content.Length -ne 0) { throw "SSE reconnect replayed acknowledged entries" }
  $remaining = docker ps -aq --filter "label=orchestraml.managed=true"
  if ($remaining) { throw "Managed job container was not removed: $remaining" }
  Write-Host "Phase 6 container execution and durable log lifecycle passed."
}
catch {
  Logs-On-Failure
  throw
}
finally {
  Remove-Container $worker
  Remove-Container $coordinator
  if (docker volume ls -q --filter "name=^${identity}$") { docker volume rm -f $identity | Out-Null }
  docker compose down --volumes | Out-Null
  $orphans = docker ps -aq --filter "label=orchestraml.managed=true"
  if ($orphans) { docker rm -f $orphans | Out-Null }
}
