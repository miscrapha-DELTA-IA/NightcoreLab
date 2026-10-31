$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (-not (Test-Path (Join-Path $PSScriptRoot "node.env"))) {
  throw "node.env nao encontrado. Extraia todos os arquivos do ZIP."
}
$exe = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $exe)) {
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) { & py -3 -m venv .venv }
  else {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw "Instale Python 3.11 ou mais recente: https://www.python.org/downloads/windows/" }
    & python -m venv .venv
  }
  if ($LASTEXITCODE -ne 0) { throw "Falha ao criar ambiente Python." }
}
& $exe -c "import yt_dlp"
if ($LASTEXITCODE -ne 0) {
  & $exe -m pip install -r requirements.txt
  if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar yt-dlp." }
}
Write-Host "Verificando a autenticacao do PC com o Render (tentativas para cold start)..." -ForegroundColor Cyan
& $exe -u agent.py --once
if ($LASTEXITCODE -ne 0) { throw ("Nao foi possivel autenticar, codigo " + $LASTEXITCODE + ". Consulte a mensagem [DIAGNOSTICO] acima.") }
Write-Host "GNARLY PC Node configurado e autenticado." -ForegroundColor Green
