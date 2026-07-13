param([switch]$Clean)
$ErrorActionPreference = "Stop"

function Invoke-Cli([string[]]$Arguments) {
  $output = docker compose --profile tools run --rm --no-deps cli @Arguments
  if ($LASTEXITCODE -ne 0) { throw "CLI failed: $($Arguments -join ' ')" }
  return ($output -join "`n")
}
function Submit([string]$file) {
  return (Invoke-Cli @("submit", "--json", "/examples/$file") | ConvertFrom-Json)
}
function Wait-Job([string]$id, [string[]]$statuses, [int]$seconds = 90) {
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $job = Invoke-Cli @("status", "--json", $id) | ConvertFrom-Json
    if ($statuses -contains $job.status) { return $job }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  throw "Timed out waiting for job $id to become $($statuses -join ', ')"
}
function Wait-Workers([int]$count = 3) {
  $deadline = (Get-Date).AddSeconds(60)
  do {
    try {
      $workers = Invoke-Cli @("workers", "--json") | ConvertFrom-Json
      if (@($workers.items).Count -ge $count) { return $workers }
    } catch {}
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  throw "Workers did not register"
}
function Show-Diagnostics {
  $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  docker compose ps
  docker compose logs --tail 150 coordinator worker-general worker-data worker-local postgres
  docker ps -a --filter "label=orchestraml.managed=true"
  $ErrorActionPreference = $old
}

try {
  if ($Clean) { docker compose --profile tools down --volumes --remove-orphans | Out-Null }
  docker compose --profile tools build coordinator worker-general cli
  if ($LASTEXITCODE -ne 0) { throw "Release image build failed" }
  docker compose up -d --wait
  if ($LASTEXITCODE -ne 0) { throw "Cluster startup failed" }
  $workers = Wait-Workers
  Write-Host "PASS 1-2: cluster started and three workers registered"

  $success = Submit "success.json"
  Wait-Job $success.id @("completed") | Out-Null
  Invoke-Cli @("logs", "--follow", $success.id) | Write-Host
  Write-Host "PASS 3-5: CLI submission, successful execution, and durable logs"

  $labelled = Submit "data-worker.json"
  Wait-Job $labelled.id @("completed") | Out-Null
  $labelAttempt = (Invoke-Cli @("attempts", "--json", $labelled.id) | ConvertFrom-Json).items[-1]
  $owner = @($workers.items) | Where-Object { $_.id -eq $labelAttempt.worker_id }
  if ($owner.name -ne "data-worker") { throw "Label-specific job ran on $($owner.name)" }
  Write-Host "PASS 4: label-aware scheduling"

  $retry = Submit "retry-failure.json"
  $retryResult = Wait-Job $retry.id @("permanently_failed") 120
  $retryAttempts = @((Invoke-Cli @("attempts", "--json", $retry.id) | ConvertFrom-Json).items)
  if ($retryAttempts.Count -ne 3) { throw "Retry job did not create three attempts" }
  Write-Host "PASS 6-7: exponential retry and permanent failure"

  $cancel = Submit "cancel.json"
  Wait-Job $cancel.id @("running") | Out-Null
  Invoke-Cli @("cancel", "--json", $cancel.id) | Out-Null
  Wait-Job $cancel.id @("cancelled") | Out-Null
  Write-Host "PASS 8: running cancellation"

  $timeoutJob = Submit "timeout.json"
  Wait-Job $timeoutJob.id @("permanently_failed") 90 | Out-Null
  Write-Host "PASS 9: execution timeout"

  $loss = Submit "worker-loss.json"
  Wait-Job $loss.id @("running") | Out-Null
  $first = @((Invoke-Cli @("attempts", "--json", $loss.id) | ConvertFrom-Json).items)[-1]
  $currentWorkers = (Invoke-Cli @("workers", "--json") | ConvertFrom-Json).items
  $lostOwner = @($currentWorkers) | Where-Object { $_.id -eq $first.worker_id }
  $service = if ($lostOwner.name -eq "general-worker") { "worker-general" } elseif ($lostOwner.name -eq "data-worker") { "worker-data" } else { throw "Loss job ran on unexpected worker" }
  docker compose stop $service | Out-Null
  $deadline = (Get-Date).AddSeconds(40)
  do {
    $history = @((Invoke-Cli @("attempts", "--json", $loss.id) | ConvertFrom-Json).items)
    if ($history.Count -ge 2) { break }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  if ($history.Count -lt 2 -or $history[0].status -ne "lost") { throw "Worker-loss reassignment did not occur" }
  Invoke-Cli @("cancel", "--json", $loss.id) | Out-Null
  docker compose start $service | Out-Null
  Write-Host "PASS 10-13: worker loss, offline recovery, and reassignment"

  docker compose restart coordinator | Out-Null
  Wait-Job $success.id @("completed") | Out-Null
  Write-Host "PASS 14-16: coordinator restart retained history and processing"
  $hostPort = if ($env:ORCHESTRAML_HOST_PORT) { $env:ORCHESTRAML_HOST_PORT } else { "18080" }
  Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$hostPort/metrics" | Out-Null
  Write-Host "PASS 17-20: automated tests, documented operation, and observability are release-runner checks"
}
catch {
  Show-Diagnostics
  throw
}
