#===========================================================================
# Install Citrix VDA
#
# Citrix Virtual Apps and Desktops 7 2507 LTSR CU1
#
# Configuration comes from Azure Automation Variables.
# Credentials come from Azure Key Vault.
# Execution occurs on an Azure Automation Hybrid Worker.
#===========================================================================

$ComputerName = Get-AutomationVariable -Name "VDAComputerName"
$Source = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw "Automation variable 'VDAComputerName' is empty or missing." }
if ([string]::IsNullOrWhiteSpace($Source)) { throw "Automation variable 'CitrixMediaPath' is empty or missing." }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "Automation variable 'KeyVaultName' is empty or missing." }
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) { throw "Automation variable 'CitrixCredentialSecretName' is empty or missing." }

Write-Output "============================================================"
Write-Output "Citrix VDA Installation"
Write-Output "============================================================"
Write-Output "Target Server : $ComputerName"
Write-Output "Source        : $Source"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

$Secret = Get-AzKeyVaultSecret `
    -VaultName $KeyVaultName `
    -Name $CredentialSecretName `
    -AsPlainText `
    -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($Secret)) {
    throw "Key Vault secret '$CredentialSecretName' is empty."
}

$CredentialData = $Secret | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) { throw "Username is missing from Key Vault secret." }
if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) { throw "Password is missing from Key Vault secret." }

$SecurePassword = ConvertTo-SecureString $CredentialData.Password -AsPlainText -Force
$Credential = [PSCredential]::new($CredentialData.Username, $SecurePassword)

Write-Output "Testing WinRM connectivity..."

Test-WSMan `
    -ComputerName $ComputerName `
    -Credential $Credential `
    -ErrorAction Stop | Out-Null

Write-Output "WinRM connectivity successful."

Invoke-Command `
    -ComputerName $ComputerName `
    -Credential $Credential `
    -ErrorAction Stop `
    -ScriptBlock {

        param([string]$Source)

        $ErrorActionPreference = "Stop"

        $Installer = Join-Path $Source "x64\XenDesktop Setup\XenDesktopVDASetup.exe"
        $LogDirectory = "C:\Temp"

        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

        Write-Output "Computer : $env:COMPUTERNAME"
        Write-Output "Installer: $Installer"

        if (-not (Test-Path -LiteralPath $Installer)) {
            throw "VDA installer not found: $Installer"
        }

        # Idempotency check
        $VDAService = Get-Service -Name "BrokerAgent" -ErrorAction SilentlyContinue

        if ($VDAService) {
            Write-Output "Citrix VDA is already installed. Skipping installation."
            Get-Service -Name "BrokerAgent" -ErrorAction SilentlyContinue |
                Format-Table Name, Status, StartType
            return
        }

        Write-Output "Installing Citrix VDA..."

        # Profile Management is a VDA-side component. Include the additional
        # component explicitly where supported by the VDA installer.
        $Arguments = @(
            "/quiet"
            "/noreboot"
            "/no_pending_reboot_check"
            "/includeadditional `"Citrix Profile Management`""
            "/logpath `"$LogDirectory`""
        ) -join " "

        $Process = Start-Process `
            -FilePath $Installer `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru

        $ExitCode = $Process.ExitCode
        Write-Output "Installer exit code: $ExitCode"

        if ($ExitCode -notin @(0, 3010, 1641)) {
            throw "Citrix VDA installation failed with exit code $ExitCode. Check $LogDirectory."
        }

        $VDAService = Get-Service -Name "BrokerAgent" -ErrorAction SilentlyContinue

        if (-not $VDAService) {
            throw "Installer returned success but the Citrix Broker Agent service was not found."
        }

        if ($VDAService.Status -ne "Running") {
            Start-Service -Name "BrokerAgent" -ErrorAction SilentlyContinue
        }

        Write-Output ""
        Write-Output "VDA installation completed."
        Write-Output ""

        Get-Service -Name "BrokerAgent" -ErrorAction SilentlyContinue |
            Format-Table Name, Status, StartType

        if ($ExitCode -eq 3010) {
            Write-Output "WARNING: Reboot required."
        }

    } -ArgumentList $Source

Write-Output "VDA runbook completed successfully."
