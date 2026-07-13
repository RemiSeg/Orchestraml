param([switch]$KeepCluster, [int]$Runs = 2)
$ErrorActionPreference = "Stop"
try {
  if ($Runs -lt 1) { throw "Runs must be positive" }
  1..$Runs | ForEach-Object {
    Write-Host "Release acceptance run $_ of $Runs"
    docker build -q -f Dockerfile.dev -t orchestraml-dev:phase7 .
    if ($LASTEXITCODE -ne 0) { throw "Development build failed" }
    docker run --rm orchestraml-dev:phase7 opam exec -- dune runtest --force
    if ($LASTEXITCODE -ne 0) { throw "OCaml test suites failed" }
    & "$PSScriptRoot/test-integration.ps1"
    & "$PSScriptRoot/test-reliability.ps1"
    & "$PSScriptRoot/test-container-logs.ps1"
    & "$PSScriptRoot/demo.ps1" -Clean
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw "git diff --check failed" }
  }
  Write-Host "All 20 release acceptance criteria passed in $Runs consecutive runs."
}
finally {
  if (-not $KeepCluster) {
    docker compose --profile tools down --volumes --remove-orphans | Out-Null
    $managed = docker ps -aq --filter "label=orchestraml.managed=true"
    if ($managed) { docker rm -f $managed | Out-Null }
  }
}
