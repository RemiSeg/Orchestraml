$ErrorActionPreference = "Stop"
$coordinatorName = "orchestraml-coordinator-test"
$workerName = "orchestraml-worker-test"
$workerIdentityVolume = "orchestraml-worker-test-identity"
function Start-TestCoordinator {
  docker run -d --name $coordinatorName --network orchestraml_default -p 18080:8080 `
    -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    -e LISTEN_ADDRESS=0.0.0.0 -e PORT=8080 `
    orchestraml-dev:phase5 opam exec -- dune exec orchestraml-coordinator -- serve | Out-Null
  $ready = $false
  1..20 | ForEach-Object {
    if (-not $ready) {
      try {
        $health = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/health -TimeoutSec 2
        if ($health.StatusCode -eq 200) { $ready = $true }
      } catch { Start-Sleep -Milliseconds 500 }
    }
  }
  if (-not $ready) { docker logs $coordinatorName; throw "Coordinator did not become healthy" }
}
function Stop-TestCoordinator {
  $container = docker ps -aq --filter "name=^/${coordinatorName}$"
  if ($container) { docker rm -f $coordinatorName | Out-Null }
}
function Start-TestWorker {
  docker run -d --name $workerName --network orchestraml_default `
    -e COORDINATOR_URL=http://orchestraml-coordinator-test:8080 `
    -e WORKER_NAME=integration-worker -e WORKER_LABELS=linux `
    -e WORKER_MAX_CONCURRENCY=1 -e WORKER_CPU_MILLICORES=1000 -e WORKER_MEMORY_MIB=512 `
    -e HEARTBEAT_INTERVAL_SECONDS=1 -e POLL_INTERVAL_SECONDS=0.2 `
    -v "${workerIdentityVolume}:/var/lib/orchestraml" `
    orchestraml-dev:phase5 opam exec -- dune exec orchestraml-worker | Out-Null
}
function Stop-TestWorker {
  $container = docker ps -aq --filter "name=^/${workerName}$"
  if ($container) { docker rm -f $workerName | Out-Null }
}
Stop-TestWorker
Stop-TestCoordinator
$identityVolume = docker volume ls -q --filter "name=^${workerIdentityVolume}$"
if ($identityVolume) { docker volume rm -f $workerIdentityVolume | Out-Null }
docker compose down --volumes
docker compose up -d --wait postgres
try {
  docker build -q -f Dockerfile.dev -t orchestraml-dev:phase5 .
  docker run --rm --network orchestraml_default `
    -e TEST_DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    orchestraml-dev:phase5 opam exec -- dune exec test/integration/test_postgres.exe
  if ($LASTEXITCODE -ne 0) { throw "PostgreSQL integration tests failed with exit code $LASTEXITCODE" }

  Start-TestCoordinator
  $headers = @{ "Idempotency-Key" = "restart-http-request" }
  $body = '{"name":"restart-job","execution":{"type":"command","executable":"true","arguments":[]},"timeout_seconds":30,"max_attempts":2,"retry":{"initial_delay_seconds":5,"multiplier":2,"maximum_delay_seconds":20,"retry_timeouts":true}}'
  $created = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/v1/jobs `
    -Method Post -Headers $headers -ContentType application/json -Body $body
  if ($created.StatusCode -ne 201) { throw "Initial coordinator did not create the job" }
  $jobId = ($created.Content | ConvertFrom-Json).id
  Stop-TestCoordinator

  Start-TestCoordinator
  $restored = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:18080/v1/jobs/$jobId"
  if ($restored.StatusCode -ne 200) { throw "Restarted coordinator could not retrieve the job" }
  $replayed = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/v1/jobs `
    -Method Post -Headers $headers -ContentType application/json -Body $body
  if ($replayed.StatusCode -ne 200 -or $replayed.Headers["Idempotency-Replayed"] -ne "true") {
    throw "Restarted coordinator did not replay the idempotent submission"
  }
  Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:18080/v1/jobs/$jobId/cancel" -Method Post | Out-Null
  $idempotentJobId = ($replayed.Content | ConvertFrom-Json).id
  Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:18080/v1/jobs/$idempotentJobId/cancel" -Method Post | Out-Null
  $remainingPending = Invoke-RestMethod "http://127.0.0.1:18080/v1/jobs?status=pending&limit=100"
  foreach ($pendingJob in @($remainingPending.items)) {
    Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:18080/v1/jobs/$($pendingJob.id)/cancel" -Method Post | Out-Null
  }

  docker volume create $workerIdentityVolume | Out-Null
  docker run --rm --user root -v "${workerIdentityVolume}:/var/lib/orchestraml" `
    orchestraml-dev:phase5 chown -R opam:opam /var/lib/orchestraml
  Start-TestWorker
  $workerReady = $false
  1..30 | ForEach-Object {
    if (-not $workerReady) {
      try {
        $workerProbe = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/v1/workers -TimeoutSec 2
        $workerProbeItems = @(($workerProbe.Content | ConvertFrom-Json).items) |
          Where-Object { $_.name -eq "integration-worker" }
        if (-not [string]::IsNullOrWhiteSpace([string]$workerProbeItems.id)) { $workerReady = $true }
        else { Start-Sleep -Milliseconds 500 }
      } catch { Start-Sleep -Milliseconds 500 }
    }
  }
  if (-not $workerReady) { docker logs $workerName; throw "Worker did not register" }
  $workersResponse = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/v1/workers
  $workerItems = @(($workersResponse.Content | ConvertFrom-Json).items) |
    Where-Object { $_.name -eq "integration-worker" }
  $stableWorkerId = [string]$workerItems.id
  if ([string]::IsNullOrWhiteSpace($stableWorkerId)) {
    throw "Registered worker response did not contain an ID: $($workersResponse.Content)"
  }
  $commandBody = '{"name":"phase4-local-command","execution":{"type":"command","executable":"/bin/true","arguments":[]},"timeout_seconds":30,"max_attempts":1,"retry":{"initial_delay_seconds":1,"multiplier":1,"maximum_delay_seconds":1,"retry_timeouts":false},"required_labels":["linux"],"resources":{"cpu_millicores":10,"memory_mib":10}}'
  $commandJob = Invoke-RestMethod http://127.0.0.1:18080/v1/jobs -Method Post `
    -ContentType application/json -Body $commandBody
  $completed = $false
  1..40 | ForEach-Object {
    if (-not $completed) {
      Start-Sleep -Milliseconds 250
      $current = Invoke-RestMethod "http://127.0.0.1:18080/v1/jobs/$($commandJob.id)"
      if ($current.status -eq "completed") { $completed = $true }
    }
  }
  if (-not $completed) { docker logs $workerName; throw "Worker did not complete the local command" }
  $attempts = Invoke-RestMethod "http://127.0.0.1:18080/v1/jobs/$($commandJob.id)/attempts"
  if (@($attempts.items).Count -ne 1 -or (@($attempts.items)[0]).status -ne "succeeded") {
    throw "Local command attempt was not persisted as succeeded"
  }
  $events = Invoke-RestMethod "http://127.0.0.1:18080/v1/jobs/$($commandJob.id)/events"
  if (@($events.items).Count -lt 4) { throw "Local command transition history is incomplete" }
  $workerAfterCompletion = Invoke-RestMethod "http://127.0.0.1:18080/v1/workers/$stableWorkerId"
  if ($workerAfterCompletion.active_jobs -ne 0 `
      -or $workerAfterCompletion.resources.reserved_cpu_millicores -ne 0 `
      -or $workerAfterCompletion.resources.reserved_memory_mib -ne 0) {
    throw "Worker capacity was not fully released: active=$($workerAfterCompletion.active_jobs) cpu=$($workerAfterCompletion.resources.reserved_cpu_millicores) memory=$($workerAfterCompletion.resources.reserved_memory_mib)"
  }
  Stop-TestWorker
  Start-TestWorker
  Start-Sleep -Seconds 2
  $workersAfterRestartResponse = Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/v1/workers
  $workersAfterRestart = @(($workersAfterRestartResponse.Content | ConvertFrom-Json).items) |
    Where-Object { $_.name -eq "integration-worker" }
  $restartedWorkerId = [string]$workersAfterRestart.id
  if ($null -eq $workersAfterRestart -or $restartedWorkerId -ne $stableWorkerId) {
    throw "Worker restart did not preserve its stable identity: before=$stableWorkerId after=$restartedWorkerId"
  }
}
finally {
  Stop-TestWorker
  Stop-TestCoordinator
  docker volume rm -f $workerIdentityVolume 2>$null | Out-Null
  docker compose down --volumes
}
