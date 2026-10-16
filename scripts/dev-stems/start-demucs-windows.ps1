# NightcoreLab v41: one-command LOCAL Windows HTDemucs + HTTPS tunnel setup.
# Run from the repository root:
#   powershell -ExecutionPolicy Bypass -File .\scripts\dev-stems\start-demucs-windows.ps1
# A personal device is required; the GitHub/Render connectors cannot execute
# this script on your Windows machine. Keep this terminal open when using stems.
[CmdletBinding()]
param([int]$Port = 8765)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$backend = Join-Path $repo "backend"
$venv = Join-Path $backend ".venv-demucs"
$pythonExe = Join-Path $venv "Scripts\python.exe"
$localFolder = Join-Path $env:LOCALAPPDATA "NightcoreLab\DevStems"
$tokenFile = Join-Path $localFolder "token.txt"
$server = $null

function Require-Tool([string]$commandName, [string]$wingetId) {
    $existing = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($existing) { return }
    Write-Host "$commandName nao encontrado; instalando $wingetId pelo winget..."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Instale $commandName manualmente e execute novamente."
    }
    & winget install --id $wingetId --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Nao foi possivel instalar $commandName" }
    # winget PATH updates may be visible only in a new terminal.
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Instalado. Reabra o PowerShell e execute este script novamente para atualizar o PATH."
    }
}

try {
    if (-not (Test-Path $backend)) { throw "Pasta backend nao encontrada: $backend" }
    if (-not (Test-Path $pythonExe)) {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3.11 -m venv $venv
            if ($LASTEXITCODE -ne 0) { throw "Instale Python 3.11 (py -3.11) e execute novamente." }
        } elseif (Get-Command python -ErrorAction SilentlyContinue) {
            & python -m venv $venv
            if ($LASTEXITCODE -ne 0) { throw "Falha ao criar ambiente virtual Python." }
        } else {
            throw "Python nao encontrado. Instale Python 3.11 e execute novamente."
        }
    }
    Require-Tool "ffmpeg" "Gyan.FFmpeg"
    Require-Tool "cloudflared" "Cloudflare.cloudflared"

    # Avoid reinstalling gigabytes of PyTorch on every restart.
    & $pythonExe -m pip show demucs *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Instalando FastAPI e Demucs (PyTorch pode demorar varios minutos)..."
        & $pythonExe -m pip install --upgrade pip
        if ($LASTEXITCODE -ne 0) { throw "Falha no pip upgrade" }
        & $pythonExe -m pip install -r (Join-Path $backend "requirements-demucs-dev.txt")
        if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar Demucs. Consulte o erro do pip acima." }
    } else {
        & $pythonExe -m pip show fastapi uvicorn *> $null
        if ($LASTEXITCODE -ne 0) {
            & $pythonExe -m pip install -r (Join-Path $backend "requirements-demucs-dev.txt")
            if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar dependencias do backend." }
        }
    }
    if (-not (Test-Path $localFolder)) {
        New-Item -ItemType Directory -Path $localFolder -Force | Out-Null
    }
    if (-not (Test-Path $tokenFile)) {
        $bytes = New-Object 'byte[]' 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        [System.IO.File]::WriteAllText($tokenFile, $secret)
    }
    $env:STEMS_DEV_ENABLED = "1"
    $env:STEMS_DEV_TOKEN = ([System.IO.File]::ReadAllText($tokenFile)).Trim()
    if ($env:STEMS_DEV_TOKEN.Length -lt 16) { throw "Token local invalido" }

    # Fail safely rather than hijacking an unrelated localhost service.
    try {
        $probe = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $Port) -UseBasicParsing -TimeoutSec 2
        if ($probe.StatusCode -eq 200) { throw "Porta $Port ocupada por outro servico; escolha -Port 8766." }
    } catch {
        if ($_.Exception.Message -like "*ocupada*") { throw }
    }
    $outLog = Join-Path $localFolder "server-stdout.log"
    $errLog = Join-Path $localFolder "server-stderr.log"
    Write-Host "Iniciando Demucs DEV em 127.0.0.1:$Port..."
    $server = Start-Process -FilePath $pythonExe `
        -ArgumentList @("-m","uvicorn","demucs_app:app","--host","127.0.0.1","--port","$Port") `
        -WorkingDirectory $backend -PassThru -NoNewWindow `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($server.HasExited) {
            throw "Backend terminou. Logs: $errLog"
        }
        try {
            $health = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $Port) -TimeoutSec 2
            if ($health.status -eq "ok" -and $health.enabled -eq $true) {
                $ready = $true
                break
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "Backend nao respondeu em 30 segundos. Logs: $errLog" }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " NIGHTCORELAB DEMUCS: SERVIDOR LOCAL ATIVO" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "No iPhone: Musica > STEMS > Separacao real - Modo DEV"
    Write-Host "  1. Ative 'Usar servidor Demucs (envia audio)'"
    Write-Host "  2. Copie a URL https://....trycloudflare.com que aparecera abaixo."
    Write-Host "  3. Cole o Token abaixo em 'Token do servidor'."
    Write-Host "  4. Toque 'Preparar/Reprocessar stems' no app."
    Write-Host ""
    Write-Host "Token pessoal: $env:STEMS_DEV_TOKEN" -ForegroundColor Yellow
    Write-Host "O token foi salvo FORA do repositorio em $tokenFile"
    Write-Host "ATENCAO: nao compartilhe esse token nem essa janela."
    Write-Host "Mantenha este PowerShell aberto; Ctrl+C encerra o tunel."
    Write-Host ""

    & cloudflared tunnel --url ("http://127.0.0.1:{0}" -f $Port)
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}
