#===========================================================================
# Validate-CitrixInstallation.ps1
#
# Validates Citrix components on a target Windows server.
# Configuration is supplied by Azure Automation Variables.
#===========================================================================

$ComputerName = Get-AutomationVariable -Name "ValidationComputerName"

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "Automation variable 'ValidationComputerName' is empty or missing."
}

$ErrorActionPreference = "Stop"

Write-Output "============================================================"
Write-Output "Citrix Installation Validation"
Write-Output "============================================================"
Write-Output "Target: $ComputerName"
Write-Output "============================================================"

Invoke-Command -ComputerName $ComputerName -ScriptBlock {

    Write-Output ""
    Write-Output "Computer: $env:COMPUTERNAME"
    Write-Output "OS:"

    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption, Version, BuildNumber |
        Format-Table -AutoSize

    Write-Output ""
    Write-Output "Citrix services:"

    Get-Service |
        Where-Object { $_.Name -like "Citrix*" -or $_.Name -eq "BrokerAgent" } |
        Select-Object Name, Status, StartType |
        Sort-Object Name |
        Format-Table -AutoSize

    Write-Output ""
    Write-Output "Citrix installation directories:"

    @(
        "C:\Program Files\Citrix\Broker"
        "C:\Program Files\Citrix\Studio"
        "C:\Program Files\Citrix\Host"
        "C:\Program Files\Citrix\Virtual Desktop Agent"
        "C:\Program Files\Citrix\Profile Management"
    ) | ForEach-Object {

        if (Test-Path -LiteralPath $_) {
            Write-Output "FOUND     : $_"
        }
        else {
            Write-Output "NOT FOUND : $_"
        }
    }

    Write-Output ""
    Write-Output "PowerShell version:"
    $PSVersionTable.PSVersion

    Write-Output ""
    Write-Output "Listening Citrix-related ports:"

    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @(80,443,1494,2598,27000,7279,8082,8083) } |
        Select-Object LocalAddress, LocalPort, OwningProcess |
        Sort-Object LocalPort |
        Format-Table -AutoSize
}

Write-Output ""
Write-Output "Citrix validation completed."
