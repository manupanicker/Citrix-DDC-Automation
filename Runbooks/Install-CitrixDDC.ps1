#===========================================================================
# Install Citrix Delivery Controller Remotely using WinRM (WSMan)
# Target: Citrix Virtual Apps and Desktops 7 2507 LTSR CU1
#
# Configuration is stored in Azure Automation Variables.
# Credentials are stored in Azure Key Vault.
#===========================================================================

$ComputerName = Get-AutomationVariable -Name "DDCComputerName"
$Source       = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw "Automation variable 'DDCComputerName' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($Source)) { throw "Automation variable 'CitrixMediaPath' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "Automation variable 'KeyVaultName' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) { throw "Automation variable 'CitrixCredentialSecretName' is empty or does not exist." }

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller Installation"
Write-Output "============================================================"
Write-Output "Target Server : $ComputerName"
Write-Output "Source        : $Source"
Write-Output "Key Vault     : $KeyVaultName"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Write-Output "Azure authentication successful."

$Secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $CredentialSecretName -AsPlainText -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($Secret)) { throw "Key Vault secret '$CredentialSecretName' is empty." }

try { $CredentialData = $Secret | ConvertFrom-Json }
catch { throw "Key Vault secret '$CredentialSecretName' is not valid JSON." }

if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) { throw "Username is missing from Key Vault secret '$CredentialSecretName'." }
if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) { throw "Password is missing from Key Vault secret '$CredentialSecretName'." }

$SecurePassword = ConvertTo-SecureString $CredentialData.Password -AsPlainText -Force
$Credential = [PSCredential]::new($CredentialData.Username, $SecurePassword)

Write-Output "Credential retrieved successfully."
Write-Output "Testing WinRM connectivity to $ComputerName..."

Test-WSMan -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop | Out-Null
Write-Output "WinRM connectivity successful."

Invoke-Command -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop -ScriptBlock {
    param([string]$Source)

    $ErrorActionPreference = "Stop"

    $Installer = Join-Path $Source "x64\XenDesktop Setup\XenDesktopServerSetup.exe"
    $LogDirectory = "C:\Temp"
    $LogFile = Join-Path $LogDirectory "CitrixDDCInstall.log"

    Write-Output "------------------------------------------------------------"
    Write-Output "Remote Citrix DDC Installation"
    Write-Output "Computer : $env:COMPUTERNAME"
    Write-Output "Source   : $Source"
    Write-Output "Installer: $Installer"
    Write-Output "Log      : $LogFile"
    Write-Output "------------------------------------------------------------"

    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

    if (-not (Test-Path -LiteralPath $Installer)) {
        throw "DDC installer not found: $Installer"
    }

    Write-Output "DDC installer found."

    $BrokerService = Get-Service -Name "CitrixBrokerService" -ErrorAction SilentlyContinue

    if ($BrokerService) {
        Write-Output "Citrix Delivery Controller is already installed. Skipping installation."
        Get-Service | Where-Object { $_.Name -like "Citrix*" } |
            Select-Object Name, Status, StartType | Sort-Object Name | Format-Table -AutoSize
        return
    }

    Write-Output "Installing Citrix Delivery Controller..."

    $Arguments = @(
        "/quiet"
        "/noreboot"
        "/no_pending_reboot_check"
        "/logpath `"$LogDirectory`""
    ) -join " "

    $Process = Start-Process -FilePath $Installer -ArgumentList $Arguments -Wait -PassThru
    $ExitCode = $Process.ExitCode

    Write-Output "Citrix installer exit code: $ExitCode"

    if ($ExitCode -notin @(0,3010,1641)) {
        throw "Citrix Delivery Controller installation failed. Exit Code: $ExitCode. Log Path: $LogDirectory"
    }

    Write-Output "Citrix installer completed successfully."

    $ServiceNames = @(
        "CitrixBrokerService"
        "CitrixConfigurationLogging"
        "CitrixHostService"
        "CitrixMachineCreationService"
        "CitrixMonitorService"
    )

    Write-Output "Validating Citrix Delivery Controller services..."

    $Services = foreach ($ServiceName in $ServiceNames) {
        Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    }

    if (-not $Services) {
        throw "Installer returned success, but expected Citrix Delivery Controller services were not found. Check $LogDirectory"
    }

    $Services | Select-Object Name, Status, StartType | Sort-Object Name | Format-Table -AutoSize

    foreach ($Service in $Services) {
        if ($Service.Status -ne "Running") {
            Write-Output "Starting service: $($Service.Name)"
            try {
                Start-Service -Name $Service.Name -ErrorAction Stop
            }
            catch {
                Write-Output "WARNING: Unable to start $($Service.Name): $($_.Exception.Message)"
            }
        }
    }

    Write-Output "Final Citrix service status:"

    foreach ($ServiceName in $ServiceNames) {
        Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    } |
        Select-Object Name, Status, StartType | Sort-Object Name | Format-Table -AutoSize

    Write-Output "Checking Citrix installation directories..."

    $CitrixPaths = @(
        "C:\Program Files\Citrix\Broker"
        "C:\Program Files\Citrix\Studio"
        "C:\Program Files\Citrix\Host"
    )

    foreach ($Path in $CitrixPaths) {
        if (Test-Path -LiteralPath $Path) {
            Write-Output "FOUND     : $Path"
        }
        else {
            Write-Output "NOT FOUND : $Path"
        }
    }

    if ($ExitCode -eq 3010) {
        Write-Output "WARNING: Reboot required."
    }

    if ($ExitCode -eq 1641) {
        Write-Output "Installer initiated a reboot."
    }

    Write-Output "============================================================"
    Write-Output "Citrix Delivery Controller installation completed."
    Write-Output "============================================================"

} -ArgumentList $Source

Write-Output "Azure Automation DDC runbook completed successfully."
