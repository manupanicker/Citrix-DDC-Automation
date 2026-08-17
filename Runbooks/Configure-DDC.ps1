#===========================================================================
# Configure-DDC.ps1
#
# Performs post-install DDC checks and prepares the controller for Site
# configuration. Site/database creation is deliberately separate.
#===========================================================================

$DDCComputerName = Get-AutomationVariable -Name "DDCComputerName"
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DDCComputerName)) { throw "DDCComputerName is missing." }

Invoke-Command -ComputerName $DDCComputerName -ScriptBlock {

    $ErrorActionPreference = "Stop"

    Write-Output "Checking Citrix Broker SDK..."
    Import-Module Citrix.Broker.Admin.V2 -ErrorAction Stop

    Write-Output "Checking Citrix Host SDK..."
    Import-Module Citrix.Host.Admin.V2 -ErrorAction SilentlyContinue

    Write-Output "Checking Citrix Configuration Logging SDK..."
    Import-Module Citrix.ConfigurationLogging.Admin.V1 -ErrorAction SilentlyContinue

    $BrokerService = Get-Service -Name CitrixBrokerService -ErrorAction SilentlyContinue

    if (-not $BrokerService) {
        throw "Citrix Broker Service is not installed."
    }

    if ($BrokerService.Status -ne "Running") {
        Start-Service -Name CitrixBrokerService -ErrorAction Stop
    }

    Write-Output "Broker Service: $(Get-Service CitrixBrokerService).Status"

    $Site = Get-BrokerSite -ErrorAction SilentlyContinue

    if ($Site) {
        Write-Output "Citrix Site detected: $($Site.Name)"
        $Site | Select-Object Name, LicenseServerName, LicenseServerPort, State | Format-Table -AutoSize
    }
    else {
        Write-Output "No Citrix Site is currently configured."
        Write-Output "Run the Site creation/configuration workflow after database prerequisites are ready."
    }
}

Write-Output "DDC post-install configuration check completed."
