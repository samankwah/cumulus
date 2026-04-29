param(
  [switch]$ForceRestart
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "local-dev.ps1")

$workspaceRoot = Get-CumulusWorkspaceRoot
$backendScript = Join-Path $workspaceRoot "backend\scripts\start-backend-local.ps1"
$frontendScript = Join-Path $workspaceRoot "frontend\start-frontend-local.ps1"
$logRoot = Get-CumulusLogRoot -Create
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

if (-not $env:NEXT_PUBLIC_API_BASE_URL) {
  $env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:8000"
}

Assert-CumulusPortAvailable -Port 8000 -Role backend -ForceRestart:$ForceRestart
Assert-CumulusPortAvailable -Port 3000 -Role frontend -ForceRestart:$ForceRestart
Remove-CumulusPidRecord -Role backend
Remove-CumulusPidRecord -Role frontend

$backendLog = Join-Path $logRoot "backend-$timestamp.log"
$backendErrorLog = Join-Path $logRoot "backend-$timestamp.err.log"
$frontendLog = Join-Path $logRoot "frontend-$timestamp.log"
$frontendErrorLog = Join-Path $logRoot "frontend-$timestamp.err.log"

Write-Host "Starting Cumulus local stack"
Write-Host "Workspace: $workspaceRoot"
Write-Host "Backend: http://127.0.0.1:8000"
Write-Host "Frontend: http://127.0.0.1:3000"
Write-Host "Frontend API base URL: $env:NEXT_PUBLIC_API_BASE_URL"
Write-Host "Logs: $logRoot"

$backendProcess = $null
$frontendProcess = $null

try {
  $backendProcess = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$backendScript`"") `
    -WorkingDirectory $workspaceRoot `
    -RedirectStandardOutput $backendLog `
    -RedirectStandardError $backendErrorLog `
    -WindowStyle Hidden `
    -PassThru
  Set-CumulusPidRecord -Role backend -Process $backendProcess -Port 8000 -LogPath $backendLog -ErrorLogPath $backendErrorLog
  Write-Host "Backend process PID: $($backendProcess.Id)"
  Wait-CumulusHttpReady -Uri "http://127.0.0.1:8000/health" -Name "Backend health endpoint" -TimeoutSeconds 120 | Out-Null

  $frontendProcess = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$frontendScript`"") `
    -WorkingDirectory $workspaceRoot `
    -RedirectStandardOutput $frontendLog `
    -RedirectStandardError $frontendErrorLog `
    -WindowStyle Hidden `
    -PassThru
  Set-CumulusPidRecord -Role frontend -Process $frontendProcess -Port 3000 -LogPath $frontendLog -ErrorLogPath $frontendErrorLog
  Write-Host "Frontend process PID: $($frontendProcess.Id)"
  Wait-CumulusHttpReady -Uri "http://127.0.0.1:3000/" -Name "Frontend" -TimeoutSeconds 120 | Out-Null
} catch {
  $startupError = $_
  Stop-CumulusRecordedServers
  throw $startupError
}

Write-Host "Cumulus local stack is ready."
Write-Host "Backend log: $backendLog"
Write-Host "Backend error log: $backendErrorLog"
Write-Host "Frontend log: $frontendLog"
Write-Host "Frontend error log: $frontendErrorLog"
Write-Host "Stop with: powershell -ExecutionPolicy Bypass -File .\scripts\stop-local.ps1"
