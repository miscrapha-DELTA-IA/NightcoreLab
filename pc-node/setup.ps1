$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not (Test-Path (Join-Path $PSScriptRoot "node.env"))) {
  Write-Host "ERRO: node.env nao encontrado. Baixe o pacote privado de ativacao do GNARLY." -ForegroundColor Red
  exit 2
}
$py = Get-Command py -ErrorAction SilentlyContinue
if ($py) { & py -3 -m venv .venv }
else {
  $python = Get-Command python -ErrorAction SilentlyContinue
  if (-not $python) {
    Write-Host "Instale o Python 3.11 ou mais recente: https://www.python.org/downloads/windows/" -ForegroundColor Red
    exit 2
  }
  & python -m venv .venv
}
$exe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
& $exe -m pip install --upgrade pip
& $exe -m pip install -r requirements.txt
if (-not (Get-Command deno -ErrorAction SilentlyContinue)) {
  Write-Host "Recomendado: instale Deno via winget install DenoLand.Deno e reabra o terminal."
}
Write-Host "Verificando a autenticacao do PC no Render..."
& $exe -u agent.py --once
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Configurado! Execute .\start.ps1 para manter o GNARLY PC Node conectado." -ForegroundColor Green
