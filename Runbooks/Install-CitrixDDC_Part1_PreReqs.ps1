#requires -RunAsAdministrator

<#
.SYNOPSIS
    Citrix Delivery Controller - Part 1
    Install Windows prerequisites from the supplied DDC reference YAML.

.NOTES
    Source-of-truth feature list:
      NET-Framework-45-Core
      GPMC
      RSAT-ADDS-Tools
      RDS-Licensing-UI
      WAS
      Telnet-Client

    This script does NOT install the Citrix Delivery Controller.
    It reports whether Windows requires a reboot after feature installation.
#>

$ErrorActionPreference = "Stop"

$LogDirectory = "C:\Logs"
$LogFile       = Join-Path $LogDirectory "DDC-Part1-Prereqs.log"

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [string]$Message
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Timestamp] $Message"
    Write-Output $Line
    Add-Content -Path $LogFile -Value $Line
}

Write-Log "============================================================"
Write-Log "Citrix Delivery Controller - Part 1"
Write-Log "Windows prerequisite installation"
Write-Log "============================================================"

$Features = @(
    "NET-Framework-45-Core"
    "GPMC"
    "RSAT-ADDS-Tools"
    "RDS-Licensing-UI"
    "WAS"
    "Telnet-Client"
)

Write-Log "Features to install:"
$Features | ForEach-Object { Write-Log "  $_" }

$FeatureResult = Install-WindowsFeature `
    -Name $Features `
    -IncludeManagementTools `
    -LogPath $LogFile

Write-Log "Install-WindowsFeature completed."
Write-Log "Success        : $($FeatureResult.Success)"
Write-Log "RestartNeeded   : $($FeatureResult.RestartNeeded)"
Write-Log "ExitCode        : $($FeatureResult.ExitCode)"

if (-not $FeatureResult.Success) {
    throw "Windows prerequisite installation failed. ExitCode: $($FeatureResult.ExitCode)"
}

if ($FeatureResult.RestartNeeded -eq "Yes") {
    Write-Log "REBOOT REQUIRED: Windows features require a reboot before Part 2."
    exit 3010
}

Write-Log "No reboot required."
Write-Log "Part 1 completed successfully."
exit 0
