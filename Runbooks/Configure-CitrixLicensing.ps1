#===========================================================================
# Configure-CitrixLicensing.ps1
#
# Configures Citrix licensing on a Delivery Controller using Citrix SDK.
# The Site must already exist before running this script.
#===========================================================================

$DDCComputerName = Get-AutomationVariable -Name "DDCComputerName"
$LicenseServerName = Get-AutomationVariable -Name "LicenseServerComputerName"
$LicensePort = Get-AutomationVariable -Name "CitrixLicensePort"

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DDCComputerName)) { throw "DDCComputerName is missing." }
if ([string]::IsNullOrWhiteSpace($LicenseServerName)) { throw "LicenseServerComputerName is missing." }
if ([string]::IsNullOrWhiteSpace($LicensePort)) { $LicensePort = "27000" }

Invoke-Command -ComputerName $DDCComputerName -ScriptBlock {
    param($LicenseServerName, $LicensePort)

    $BrokerModule = Get-Module -ListAvailable -Name Citrix.Broker.Admin.V2 |
        Select-Object -First 1

    if (-not $BrokerModule) {
        throw "Citrix Broker PowerShell SDK is not installed on this DDC."
    }

    Import-Module Citrix.Broker.Admin.V2 -ErrorAction Stop

    $Current = Get-BrokerSite -ErrorAction Stop

    Write-Output "Current License Server: $($Current.LicenseServerName)"
    Write-Output "Current License Port  : $($Current.LicenseServerPort)"

    Set-BrokerSite `
        -LicenseServerName $LicenseServerName `
        -LicenseServerPort ([int]$LicensePort) `
        -ErrorAction Stop

    $Updated = Get-BrokerSite -ErrorAction Stop

    Write-Output "Updated License Server: $($Updated.LicenseServerName)"
    Write-Output "Updated License Port  : $($Updated.LicenseServerPort)"

} -ArgumentList $LicenseServerName, $LicensePort

Write-Output "Citrix licensing configuration completed."
