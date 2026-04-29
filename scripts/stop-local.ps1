$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "local-dev.ps1")

Stop-CumulusRecordedServers
