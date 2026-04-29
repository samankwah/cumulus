$script:CumulusLocalDevScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CumulusLocalDevWorkspaceRoot = Split-Path -Parent $script:CumulusLocalDevScriptRoot
$script:CumulusLocalDevStateRoot = Join-Path $script:CumulusLocalDevWorkspaceRoot ".cumulus-local"
$script:CumulusLocalDevLogRoot = Join-Path $script:CumulusLocalDevStateRoot "logs"
$script:CumulusLocalDevPidFile = Join-Path $script:CumulusLocalDevStateRoot "pids.json"

function Get-CumulusWorkspaceRoot {
  return $script:CumulusLocalDevWorkspaceRoot
}

function Get-CumulusStateRoot {
  param([switch]$Create)

  if ($Create -and -not (Test-Path $script:CumulusLocalDevStateRoot)) {
    New-Item -ItemType Directory -Path $script:CumulusLocalDevStateRoot -Force | Out-Null
  }

  return $script:CumulusLocalDevStateRoot
}

function Get-CumulusLogRoot {
  param([switch]$Create)

  if ($Create) {
    Get-CumulusStateRoot -Create | Out-Null
    if (-not (Test-Path $script:CumulusLocalDevLogRoot)) {
      New-Item -ItemType Directory -Path $script:CumulusLocalDevLogRoot -Force | Out-Null
    }
  }

  return $script:CumulusLocalDevLogRoot
}

function Get-CumulusPidFilePath {
  param([switch]$Create)

  if ($Create) {
    Get-CumulusStateRoot -Create | Out-Null
  }

  return $script:CumulusLocalDevPidFile
}

function Get-CumulusCommandPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $command = Get-Command $Name -ErrorAction Stop
  return $command.Source
}

function Get-CumulusProcessDetails {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
  )

  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  $commandLine = $null
  $executablePath = $null
  $parentProcessId = $null

  try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    $commandLine = $cim.CommandLine
    $executablePath = $cim.ExecutablePath
    $parentProcessId = $cim.ParentProcessId
  } catch {
    # Process details are best-effort; Get-Process still gives enough for diagnostics.
  }

  $startTime = $null
  if ($process) {
    try {
      $startTime = $process.StartTime.ToString("o")
    } catch {
      $startTime = $null
    }
  }

  return [pscustomobject]@{
    ProcessId       = $ProcessId
    ProcessName     = if ($process) { $process.ProcessName } else { $null }
    CommandLine     = $commandLine
    ExecutablePath  = $executablePath
    ParentProcessId = $parentProcessId
    StartTime       = $startTime
    Exists          = [bool]$process
  }
}

function Get-CumulusPortListeners {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Port
  )

  $processIds = @()

  try {
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    foreach ($connection in $connections) {
      if ($connection.OwningProcess -and $processIds -notcontains [int]$connection.OwningProcess) {
        $processIds += [int]$connection.OwningProcess
      }
    }
  } catch {
    $netstatLines = @(netstat -ano)
    $pattern = "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$"
    foreach ($line in $netstatLines) {
      if ($line -match $pattern) {
        $ownerProcessId = [int]$Matches[1]
        if ($processIds -notcontains $ownerProcessId) {
          $processIds += $ownerProcessId
        }
      }
    }
  }

  $listeners = @()
  foreach ($ownerProcessId in $processIds) {
    $details = Get-CumulusProcessDetails -ProcessId $ownerProcessId
    $listeners += [pscustomobject]@{
      Port            = $Port
      ProcessId       = $details.ProcessId
      ProcessName     = $details.ProcessName
      CommandLine     = $details.CommandLine
      ExecutablePath  = $details.ExecutablePath
      ParentProcessId = $details.ParentProcessId
      StartTime       = $details.StartTime
      Exists          = $details.Exists
    }
  }

  return $listeners
}

function Format-CumulusListenerSummary {
  param(
    [Parameter(Mandatory = $true)]
    $Listener
  )

  $processName = if ($Listener.ProcessName) { $Listener.ProcessName } else { "unknown" }
  $commandLine = if ($Listener.CommandLine) { $Listener.CommandLine } else { "command line unavailable" }
  return "PID $($Listener.ProcessId) ($processName): $commandLine"
}

function Test-CumulusLocalServerProcess {
  param(
    [Parameter(Mandatory = $true)]
    $ProcessInfo,

    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role
  )

  $commandLine = if ($ProcessInfo.CommandLine) { $ProcessInfo.CommandLine.ToLowerInvariant() } else { "" }
  $executablePath = if ($ProcessInfo.ExecutablePath) { $ProcessInfo.ExecutablePath.ToLowerInvariant() } else { "" }
  $workspaceRoot = (Get-CumulusWorkspaceRoot).ToLowerInvariant()

  if ($Role -eq "backend") {
    return (
      ($commandLine -match "cumulus\.main:app" -and $commandLine -match "uvicorn") -or
      ($commandLine -like "*start-backend-local.ps1*") -or
      ($commandLine -like "*$workspaceRoot*" -and $commandLine -match "uvicorn")
    )
  }

  return (
    ($commandLine -like "*start-frontend-local.ps1*") -or
    ($commandLine -like "*start-frontend-production-local.ps1*") -or
    ($commandLine -like "*start-production.mjs*") -or
    ($commandLine -like "*$workspaceRoot*" -and ($commandLine -match "next(\.js)?\s+dev" -or $commandLine -like "*node_modules*next*")) -or
    ($executablePath -like "*$workspaceRoot*" -and $commandLine -match "next")
  )
}

function Test-CumulusLocalPortService {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role
  )

  try {
    if ($Role -eq "backend") {
      $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2
      if ([int]$response.StatusCode -ne 200) {
        return $false
      }

      try {
        $payload = $response.Content | ConvertFrom-Json
        return $payload.project_name -eq "cumulus"
      } catch {
        return $response.Content -match '"project_name"\s*:\s*"cumulus"'
      }
    }

    $frontendResponse = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 3
    return (
      [int]$frontendResponse.StatusCode -eq 200 -and
      $frontendResponse.Content -match "Cumulus" -and
      $frontendResponse.Content -match "Ghana Seasonal Advisory Map"
    )
  } catch {
    return $false
  }
}

function Wait-CumulusPortReleased {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Port,

    [int]$TimeoutSeconds = 10
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-CumulusPortListeners -Port $Port).Count -eq 0) {
      return
    }
    Start-Sleep -Milliseconds 250
  }

  throw "Port $Port did not become available within $TimeoutSeconds seconds."
}

function Stop-CumulusPortListeners {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role
  )

  $listeners = @(Get-CumulusPortListeners -Port $Port)
  if ($listeners.Count -eq 0) {
    return
  }

  $portServiceLooksLocal = Test-CumulusLocalPortService -Port $Port -Role $Role
  foreach ($listener in $listeners) {
    if (-not (Test-CumulusLocalServerProcess -ProcessInfo $listener -Role $Role) -and -not $portServiceLooksLocal) {
      $summary = Format-CumulusListenerSummary -Listener $listener
      throw "Refusing to stop port $Port because the listener does not look like the local Cumulus $Role server. $summary"
    }
  }

  foreach ($listener in $listeners) {
    $summary = Format-CumulusListenerSummary -Listener $listener
    Write-Host "Stopping existing Cumulus $Role listener on port ${Port}: $summary"
    Stop-CumulusProcessTree -ProcessId ([int]$listener.ProcessId) -ExpectedStartTime $listener.StartTime
  }

  Wait-CumulusPortReleased -Port $Port
}

function Stop-CumulusProcessTree {
  param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [string]$ExpectedStartTime
  )

  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $process) {
    return
  }

  if ($ExpectedStartTime) {
    $actualStartTime = $null
    try {
      $actualStartTime = $process.StartTime.ToString("o")
    } catch {
      $actualStartTime = $null
    }

    if ($actualStartTime -and $actualStartTime -ne $ExpectedStartTime) {
      throw "Refusing to stop PID $ProcessId because it no longer matches the recorded process start time."
    }
  }

  $children = @()
  try {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction Stop)
  } catch {
    $children = @()
  }

  foreach ($child in $children) {
    Stop-CumulusProcessTree -ProcessId ([int]$child.ProcessId)
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Assert-CumulusPortAvailable {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role,

    [switch]$ForceRestart
  )

  $listeners = @(Get-CumulusPortListeners -Port $Port)
  if ($listeners.Count -eq 0) {
    return
  }

  if ($ForceRestart) {
    Stop-CumulusPortListeners -Port $Port -Role $Role
    return
  }

  $summaries = @()
  foreach ($listener in $listeners) {
    $summaries += Format-CumulusListenerSummary -Listener $listener
  }

  $message = @(
    "Port $Port is already in use; Cumulus $Role was not started.",
    ($summaries -join [Environment]::NewLine),
    "Stop the existing process or rerun with -ForceRestart to replace a detected local Cumulus $Role server."
  ) -join [Environment]::NewLine

  throw $message
}

function Wait-CumulusHttpReady {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [int]$ExpectedStatus = 200,

    [int]$TimeoutSeconds = 90
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastError = $null

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 3
      if ([int]$response.StatusCode -eq $ExpectedStatus) {
        return $response
      }
      $lastError = "Received HTTP $($response.StatusCode)"
    } catch {
      $lastError = $_.Exception.Message
    }

    Start-Sleep -Seconds 1
  }

  throw "$Name did not return HTTP $ExpectedStatus at $Uri within $TimeoutSeconds seconds. Last error: $lastError"
}

function Read-CumulusPidState {
  $state = [ordered]@{}
  $pidFile = Get-CumulusPidFilePath

  if (-not (Test-Path $pidFile)) {
    return $state
  }

  $content = Get-Content -Raw -Path $pidFile
  if (-not $content.Trim()) {
    return $state
  }

  $json = $content | ConvertFrom-Json
  foreach ($property in $json.PSObject.Properties) {
    $state[$property.Name] = $property.Value
  }

  return $state
}

function Write-CumulusPidState {
  param(
    [Parameter(Mandatory = $true)]
    $State
  )

  $pidFile = Get-CumulusPidFilePath -Create

  if ($State.Count -eq 0) {
    if (Test-Path $pidFile) {
      Remove-Item -LiteralPath $pidFile -Force
    }
    return
  }

  $State | ConvertTo-Json -Depth 6 | Set-Content -Path $pidFile -Encoding UTF8
}

function Set-CumulusPidRecord {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role,

    [Parameter(Mandatory = $true)]
    $Process,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [Parameter(Mandatory = $true)]
    [string]$LogPath,

    [Parameter(Mandatory = $true)]
    [string]$ErrorLogPath
  )

  $state = Read-CumulusPidState
  $processStartTime = $null
  try {
    $processStartTime = $Process.StartTime.ToString("o")
  } catch {
    $details = Get-CumulusProcessDetails -ProcessId ([int]$Process.Id)
    $processStartTime = $details.StartTime
  }

  $state[$Role] = [ordered]@{
    pid          = [int]$Process.Id
    port         = $Port
    startTime    = $processStartTime
    startedAt    = (Get-Date).ToString("o")
    logPath      = $LogPath
    errorLogPath = $ErrorLogPath
  }

  Write-CumulusPidState -State $state
}

function Remove-CumulusPidRecord {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("backend", "frontend")]
    [string]$Role
  )

  $state = Read-CumulusPidState
  if ($state.Contains($Role)) {
    $state.Remove($Role)
    Write-CumulusPidState -State $state
  }
}

function Stop-CumulusRecordedServers {
  $state = Read-CumulusPidState
  if ($state.Count -eq 0) {
    Write-Host "No recorded Cumulus local server PIDs found."
    return
  }

  foreach ($role in @("frontend", "backend")) {
    if (-not $state.Contains($role)) {
      continue
    }

    $record = $state[$role]
    $recordProcessId = [int]$record.pid
    $recordStartTime = if ($record.startTime) { [string]$record.startTime } else { $null }
    $recordPort = if ($record.port) { [int]$record.port } else { $null }
    $process = Get-Process -Id $recordProcessId -ErrorAction SilentlyContinue

    if (-not $process) {
      Write-Host "Recorded Cumulus $role PID $recordProcessId is no longer running."
      Remove-CumulusPidRecord -Role $role
      continue
    }

    try {
      Write-Host "Stopping recorded Cumulus $role PID $recordProcessId."
      Stop-CumulusProcessTree -ProcessId $recordProcessId -ExpectedStartTime $recordStartTime
      if ($recordPort) {
        try {
          Wait-CumulusPortReleased -Port $recordPort -TimeoutSeconds 3
        } catch {
          Stop-CumulusPortListeners -Port $recordPort -Role $role
        }
      }
      Remove-CumulusPidRecord -Role $role
    } catch {
      Write-Host $_.Exception.Message
      throw
    }
  }
}
