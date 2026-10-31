$ErrorActionPreference = "Stop"
$startup = [Environment]::GetFolderPath("Startup")
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup "GNARLY PC Audio Node.lnk"))
$shortcut.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot "start.ps1") + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Save()
Write-Host "GNARLY PC Node sera iniciado quando voce entrar no Windows."
