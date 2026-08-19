#requires -RunAsAdministrator

<#
.SYNOPSIS
    Citrix Delivery Controller - Part 2
    Install the DDC components using the exact installer arguments
    supplied in the reference YAML.

.NOTES
    Part 3 / RunOnce resume handling is intentionally NOT included.
#>

$ErrorActionPreference = "Stop"

$CitrixPath = $env:CITRIX_PATH
if ([string]::IsNullOrWhiteSpace($CitrixPath)) {
    $CitrixPath = "C:\Source\CVAD"
}

$Installer = Join-Path $CitrixPath "x64\XenDesktop Setup\XenDesktopServerSetup.exe"

$LogDirectory = "C:\Logs"
$LogFile       = Join-Path $LogDirectory "DDC-Part2-Install.log"

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
Write-Log "Citrix Delivery Controller - Part 2"
Write-Log "DDC component installation"
Write-Log "============================================================"

Write-Log "Installer : $Installer"
Write-Log "Log       : $LogDirectory"

if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) {
    throw "Citrix Delivery Controller installer not found: $Installer"
}

$Arguments = @(
    "/components controller,desktopstudio"
    "/configure_firewall"
    "/nosql"
    "/disableexperiencemetrics"
    "/noreboot"
    "/quiet"
    "/logpath `"$LogDirectory`""
    "/IGNORE_HW_CHECK_FAILURE"
) -join " "

Write-Log "Starting Citrix Delivery Controller installer."
Write-Log "Arguments: $Arguments"

$Process = Start-Process `
    -FilePath $Installer `
    -ArgumentList $Arguments `
    -PassThru `
    -Wait

$ExitCode = $Process.ExitCode

Write-Log "Citrix installer completed."
Write-Log "Process ID : $($Process.Id)"
Write-Log "Exit Code  : $ExitCode"

switch ($ExitCode) {
    0 {
        Write-Log "DDC installation completed successfully."
        exit 0
    }

    3 {
        Write-Log "Citrix installer returned expected code 3."
        exit 3
    }

    3010 {
        Write-Log "Citrix installer completed and requires a reboot."
        exit 3010
    }

    default {
        throw "Citrix Delivery Controller installation failed with exit code $ExitCode. Check $LogDirectory for Citrix logs."
    }
}
