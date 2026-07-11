$ErrorActionPreference = "Stop"
docker compose down --volumes
docker compose up -d --wait postgres
$coordinatorName = "orchestraml-coordinator-test"
function Start-TestCoordinator {
  docker run -d --name $coordinatorName --network orchestraml_default -p 18080:8080 `
    -e DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    -e LISTEN_ADDRESS=0.0.0.0 -e PORT=8080 `
    orchestraml-dev:phase3 opam exec -- dune exec orchestraml-coordinator -- serve | Out-Null
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
  docker rm -f $coordinatorName 2>$null | Out-Null
}
try {
  docker build -q -f Dockerfile.dev -t orchestraml-dev:phase3 .
  docker run --rm --network orchestraml_default `
    -e TEST_DATABASE_URL=postgresql://orchestraml:orchestraml@postgres:5432/orchestraml `
    orchestraml-dev:phase3 opam exec -- dune exec test/integration/test_postgres.exe
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
}
finally {
  Stop-TestCoordinator
  docker compose down --volumes
}
