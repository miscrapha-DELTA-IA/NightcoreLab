$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
Write-Host "GNARLY PC Node - diagnostico e reconexao sem reinstalar" -ForegroundColor Cyan
$exe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $exe)) {
  Write-Host "Ambiente Python nao encontrado. Executando setup..." -ForegroundColor Yellow
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "setup.ps1")
  if ($LASTEXITCODE -ne 0) { throw ("Configuracao falhou (" + $LASTEXITCODE + ").") }
} else {
  & $exe -u (Join-Path $PSScriptRoot "agent.py") --once
  if ($LASTEXITCODE -ne 0) { throw ("Falha no teste (" + $LASTEXITCODE + "). Consulte a linha [DIAGNOSTICO] acima.") }
}
Write-Host "[OK] Conexao ao Render verificada. Iniciando agente..." -ForegroundColor Green
Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File",('"'+(Join-Path $PSScriptRoot "start.ps1")+'"')) -WorkingDirectory $PSScriptRoot
