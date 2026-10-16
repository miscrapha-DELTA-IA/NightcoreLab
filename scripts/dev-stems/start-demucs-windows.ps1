# NightcoreLab HTDemucs local Windows launcher (Python 3.15-first).
# Usage from repo root:
# powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev-stems\start-demucs-windows.ps1
# Python 3.15 uses official PyTorch nightly CPU wheels and Demucs 4.1.0;
# if that fails, Python 3.11 is installed in parallel via "py install 3.11".
# The system's default Python is never changed.
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [ValidateSet("auto", "3.15", "3.11")]
    [string]$PythonVersion = "auto"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$backend = Join-Path $repo "backend"
$localFolder = Join-Path $env:LOCALAPPDATA "NightcoreLab\DevStems"
$tokenFile = Join-Path $localFolder "token.txt"
$server = $null

function Require-Tool([string]$commandName, [string]$wingetId) {
    if (Get-Command $commandName -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$commandName nao encontrado. Instale $wingetId e execute novamente."
    }
    Write-Host "Instalando $commandName ($wingetId)..."
    & winget install --id $wingetId --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar $commandName." }
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "$commandName instalado. Feche e reabra o terminal e execute novamente para atualizar o PATH."
    }
}

function Has-Python([string]$version) {
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) { return $false }
    try {
        & py "-$version" -c "import sys; assert sys.version_info[:2] == tuple(map(int, '$version'.split('.')))" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Install-Python311 {
    if (Has-Python "3.11") { return }
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw "O comando py nao foi encontrado. Instale o Python Installation Manager para o fallback."
    }
    Write-Host "Python 3.15 nao validou as bibliotecas do Demucs; instalando Python 3.11 isoladamente..."
    & py install 3.11
    if ($LASTEXITCODE -ne 0 -or -not (Has-Python "3.11")) {
        throw "Instalacao automatica do Python 3.11 falhou. Tente 'py install 3.11'."
    }
}

function Invoke-Pip([string]$interpreter, [string[]]$args, [string]$step) {
    Write-Host $step
    & $interpreter -m pip @args
    if ($LASTEXITCODE -ne 0) {
        throw "$step falhou (codigo $LASTEXITCODE)."
    }
}

function Test-Demucs([string]$interpreter) {
    try {
        # Tests actual import AND command-line initialization, not only pip metadata.
        & $interpreter -c "import torch, demucs, fastapi, uvicorn" *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        & $interpreter -m demucs --help *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Install-DemucsFor([string]$version) {
    $environment = Join-Path $backend (".venv-demucs-" + $version)
    $interpreter = Join-Path $environment "Scripts\python.exe"
    if (-not (Test-Path $interpreter)) {
        Write-Host "Criando venv Python $version em $environment..."
        & py "-$version" -m venv $environment
        if ($LASTEXITCODE -ne 0) { throw "Falha ao criar venv Python $version." }
    }
    if (Test-Demucs $interpreter) {
        Write-Host "Demucs ja disponivel e verificado em Python $version." -ForegroundColor Green
        return $interpreter
    }
    Invoke-Pip $interpreter @("install", "--upgrade", "pip", "setuptools", "wheel") "Atualizando pip e ferramentas do Python $version..."
    if ($version -eq "3.15") {
        Write-Host "Tentando PyTorch CPU nightly oficial para Python 3.15 (Windows)..."
        Invoke-Pip $interpreter @(
            "install", "--pre", "torch",
            "--index-url", "https://download.pytorch.org/whl/nightly/cpu"
        ) "Instalando torch cp315..."
        Invoke-Pip $interpreter @(
            "install", "-r", (Join-Path $backend "requirements-demucs-dev-315.txt")
        ) "Instalando Demucs 4.1 e servidor Python 3.15..."
    } else {
        # Torchaudio 2.7+ removed the older writer used by Demucs 4.0.1.
        # Keep the stable 2.6 CPU versions together on the automatic fallback.
        Invoke-Pip $interpreter @(
            "install", "torch==2.6.0", "torchaudio==2.6.0",
            "--index-url", "https://download.pytorch.org/whl/cpu"
        ) "Instalando torch/torchaudio CPU 2.6 para Python 3.11..."
        Invoke-Pip $interpreter @(
            "install", "-r", (Join-Path $backend "requirements-demucs-dev.txt")
        ) "Instalando Demucs estavel 4.0.1 no Python 3.11..."
    }
    if (-not (Test-Demucs $interpreter)) {
        throw "Demucs nao iniciou com Python $version. Verifique os logs do pip acima."
    }
    Write-Host "Demucs confirmado em Python $version." -ForegroundColor Green
    return $interpreter
}

try {
    if (-not (Test-Path $backend)) { throw "Pasta backend nao encontrada: $backend" }
    if (-not (Get-Command py -ErrorAction SilentlyContinue)) {
        throw "Instale o Python Installation Manager e reabra o PowerShell para disponibilizar o comando py."
    }

    $versions = if ($PythonVersion -eq "auto") { @("3.15", "3.11") } else { @($PythonVersion) }
    $pythonExe = $null
    foreach ($version in $versions) {
        try {
            if ($version -eq "3.11") { Install-Python311 }
            elseif (-not (Has-Python "3.15")) {
                Write-Host "Python 3.15 nao encontrado; tentando 3.11..."
                if ($PythonVersion -ne "auto") { throw "Python 3.15 nao esta instalado." }
                continue
            }
            $pythonExe = Install-DemucsFor $version
            Write-Host "Interpretador escolhido: Python $version" -ForegroundColor Green
            break
        } catch {
            Write-Warning ("Python " + $version + ": " + $_.Exception.Message)
            if ($PythonVersion -ne "auto") { throw }
        }
    }
    if (-not $pythonExe) { throw "Nao foi possivel instalar um Demucs funcional com Python 3.15 nem 3.11." }

    Require-Tool "ffmpeg" "Gyan.FFmpeg"
    Require-Tool "cloudflared" "Cloudflare.cloudflared"

    if (-not (Test-Path $localFolder)) {
        New-Item -ItemType Directory -Path $localFolder -Force | Out-Null
    }
    if (-not (Test-Path $tokenFile)) {
        $bytes = New-Object "byte[]" 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $secret = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        [System.IO.File]::WriteAllText($tokenFile, $secret)
    }
    $env:STEMS_DEV_ENABLED = "1"
    $env:STEMS_DEV_TOKEN = [System.IO.File]::ReadAllText($tokenFile).Trim()
    if ($env:STEMS_DEV_TOKEN.Length -lt 16) { throw "Token local invalido." }

    # Do not start on a port which already belongs to a different service.
    try {
        $probe = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $Port) -UseBasicParsing -TimeoutSec 2
        if ($probe.StatusCode -eq 200) { throw "Porta $Port ocupada. Tente -Port 8766." }
    } catch {
        if ($_.Exception.Message -like "*ocupada*") { throw }
    }

    $outLog = Join-Path $localFolder "server-stdout.log"
    $errLog = Join-Path $localFolder "server-stderr.log"
    Write-Host "Iniciando Demucs DEV em 127.0.0.1:$Port..."
    $server = Start-Process -FilePath $pythonExe -ArgumentList @(
        "-m", "uvicorn", "demucs_app:app", "--host", "127.0.0.1", "--port", "$Port"
    ) -WorkingDirectory $backend -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        if ($server.HasExited) {
            throw "Backend terminou. Consulte: $errLog"
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
    if (-not $ready) { throw "Backend nao respondeu. Consulte: $errLog" }

    Write-Host ""
    Write-Host "NIGHTCORELAB DEMUCS LOCAL: SERVIDOR ATIVO" -ForegroundColor Green
    Write-Host "iPhone: Musica > STEMS > Separacao real > Modo DEV"
    Write-Host "Ative Demucs, copie o endereco HTTPS do tunel e o token abaixo."
    Write-Host "Toque 'Preparar com Demucs' na faixa carregada."
    Write-Host "Token pessoal: $env:STEMS_DEV_TOKEN" -ForegroundColor Yellow
    Write-Host "Token salvo fora do repo em $tokenFile"
    Write-Host "Nao compartilhe o token nem esta janela."
    Write-Host "Mantenha o PowerShell aberto enquanto estiver usando o servidor."
    Write-Host ""
    & cloudflared tunnel --url ("http://127.0.0.1:{0}" -f $Port)
} finally {
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
}
