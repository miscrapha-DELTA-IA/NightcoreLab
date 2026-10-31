$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$exe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $exe)) { throw "Execute setup.ps1 primeiro." }
& $exe -u (Join-Path $PSScriptRoot "agent.py")
