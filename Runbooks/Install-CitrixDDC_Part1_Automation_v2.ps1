$ErrorActionPreference = "Continue"

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller - Part 1"
Write-Output "DDC Prerequisites"
Write-Output "============================================================"

# ------------------------------------------------------------
# Automation variables - SAME as working DDC runbook
# ------------------------------------------------------------

$ComputerName = Get-AutomationVariable -Name "DDCComputerName"
$Source = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw "Automation variable 'DDCComputerName' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($Source)) { throw "Automation variable 'CitrixMediaPath' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "Automation variable 'KeyVaultName' is empty or does not exist." }
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) { throw "Automation variable 'CitrixCredentialSecretName' is empty or does not exist." }

Write-Output "Target Server : $ComputerName"
Write-Output "UNC Source    : $Source"
Write-Output "Key Vault     : $KeyVaultName"
Write-Output "Secret Name   : $CredentialSecretName"

# ------------------------------------------------------------
# Azure modules - same framework as working DDC runbook
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Loading Azure PowerShell modules"
Write-Output "============================================================"

try {
    Import-Module Az.Accounts -Force -ErrorAction Stop
    Write-Output "Az.Accounts : $((Get-Module Az.Accounts).Version)"

    Import-Module Az.KeyVault -Force -ErrorAction Stop
    Write-Output "Az.KeyVault : $((Get-Module Az.KeyVault).Version)"
}
catch {
    Write-Output "Azure module loading failed."
    Write-Output "Error : $($_.Exception.Message)"
    throw
}

# ------------------------------------------------------------
# Azure authentication - same as working DDC runbook
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Connecting to Azure"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Write-Output "Azure authentication: SUCCESS"

# ------------------------------------------------------------
# Key Vault using Managed Identity REST API
# SAME mechanism as working DDC runbook
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Retrieving credential from Key Vault"
Write-Output "============================================================"

Write-Output "Vault  : $KeyVaultName"
Write-Output "Secret : $CredentialSecretName"
Write-Output ""
Write-Output "Requesting Managed Identity token..."

$TokenResponse = Invoke-RestMethod `
    -Method GET `
    -Headers @{ Metadata = "true" } `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
    -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($TokenResponse.access_token)) {
    throw "Managed Identity token for Key Vault was not returned."
}

Write-Output "Managed Identity token: SUCCESS"

$Headers = @{
    Authorization = "Bearer $($TokenResponse.access_token)"
}

$VaultUri = "https://$KeyVaultName.vault.azure.net"
$SecretUri = "{0}/secrets/{1}?api-version=7.4" -f $VaultUri, $CredentialSecretName

Write-Output ""
Write-Output "Key Vault URI:"
Write-Output $VaultUri
Write-Output ""
Write-Output "Secret URI:"
Write-Output $SecretUri
Write-Output ""
Write-Output "Calling Key Vault REST API..."

$SecretResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $SecretUri `
    -Headers $Headers `
    -ErrorAction Stop

if ($null -eq $SecretResponse) {
    throw "Key Vault returned NULL response."
}

if ([string]::IsNullOrWhiteSpace($SecretResponse.value)) {
    throw "Key Vault returned an empty secret."
}

Write-Output "Key Vault REST call: SUCCESS"
Write-Output "Secret value retrieved successfully."

# ------------------------------------------------------------
# Process credential - same as working DDC runbook
# ------------------------------------------------------------

Write-Output ""
Write-Output "Processing credential..."

try {
    $CredentialData = $SecretResponse.value | ConvertFrom-Json
}
catch {
    throw "Key Vault secret '$CredentialSecretName' is not valid JSON."
}

if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) {
    throw "Username is missing from Key Vault secret '$CredentialSecretName'."
}

if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) {
    throw "Password is missing from Key Vault secret '$CredentialSecretName'."
}

$SecurePassword = ConvertTo-SecureString `
    $CredentialData.Password `
    -AsPlainText `
    -Force

$Credential = New-Object System.Management.Automation.PSCredential(
    $CredentialData.Username,
    $SecurePassword
)

Write-Output "Credential loaded successfully."
Write-Output "Username : $($CredentialData.Username)"

# ------------------------------------------------------------
# WinRM connectivity - same as working DDC runbook
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Testing WinRM"
Write-Output "============================================================"

Test-WSMan `
    -ComputerName $ComputerName `
    -Authentication Negotiate `
    -Credential $Credential `
    -ErrorAction Stop | Out-Null

Write-Output "WinRM connectivity: SUCCESS"

# ------------------------------------------------------------
# Create remote PowerShell session
# ------------------------------------------------------------

Write-Output ""
Write-Output "Creating remote PowerShell session..."

$Session = New-PSSession `
    -ComputerName $ComputerName `
    -Authentication Negotiate `
    -Credential $Credential `
    -ErrorAction Stop

Write-Output "Remote session: SUCCESS"

$RebootCount = 0
$MaxReboots = 6

try {

    # --------------------------------------------------------
    # Pre-flight
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PART 1 PRE-FLIGHT VALIDATION"
    Write-Output "============================================================"

    $Preflight = Invoke-Command -Session $Session -ScriptBlock {

        $OS = Get-CimInstance Win32_OperatingSystem
        $Computer = Get-CimInstance Win32_ComputerSystem

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            OS = $OS.Caption
            OSBuild = $OS.BuildNumber
            DomainJoined = [bool]$Computer.PartOfDomain
            Domain = $Computer.Domain
            IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
            PowerShell = $PSVersionTable.PSVersion.ToString()
        }

    } -ErrorAction Stop

    $Preflight | Format-List | Out-String | Write-Output

    if (-not $Preflight.DomainJoined) {
        throw "DDC target is not domain joined."
    }

    if ($Preflight.IsDomainController) {
        throw "DDC installation target is a Domain Controller."
    }

    Write-Output "DDC pre-flight validation: SUCCESS"

    # --------------------------------------------------------
    # Exact prerequisite list from supplied YAML
    # --------------------------------------------------------

    $FeatureNames = @(
        "NET-Framework-45-Core"
        "GPMC"
        "RSAT-ADDS-Tools"
        "RDS-Licensing-UI"
        "WAS"
        "Telnet-Client"
    )

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Installing DDC Prerequisites"
    Write-Output "============================================================"

    $FeatureResult = Invoke-Command `
        -Session $Session `
        -ScriptBlock {

            param($Features)

            Write-Output "Installing Windows features:"
            $Features | ForEach-Object {
                Write-Output "  $_"
            }

            Install-WindowsFeature `
                -Name $Features `
                -IncludeManagementTools

        } `
        -ArgumentList (,$FeatureNames) `
        -ErrorAction Stop

    $FeatureResult | Format-List | Out-String | Write-Output

    if ($FeatureResult.Success -ne $true) {
        throw "DDC prerequisite installation failed."
    }

    # --------------------------------------------------------
    # Reboot if Windows features require it
    # --------------------------------------------------------

    $RestartNeeded = $FeatureResult.RestartNeeded

    if ($RestartNeeded -eq "Yes") {

        $RebootCount++

        if ($RebootCount -gt $MaxReboots) {
            throw "Maximum automatic reboot limit of $MaxReboots reached."
        }

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "REBOOT REQUIRED BY DDC PREREQUISITES"
        Write-Output "============================================================"
        Write-Output "Automatic reboot: $RebootCount of $MaxReboots"
        Write-Output "Rebooting target server..."

        try {
            Invoke-Command -Session $Session -ScriptBlock {
                Restart-Computer -Force
            } -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Output "Expected WinRM disconnect during reboot: $($_.Exception.Message)"
        }

        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
        $Session = $null

        Write-Output "Waiting for target server to return through WinRM..."

        $ServerBack = $false

        for ($Attempt = 1; $Attempt -le 30; $Attempt++) {

            Start-Sleep -Seconds 10

            try {
                Test-WSMan `
                    -ComputerName $ComputerName `
                    -Authentication Negotiate `
                    -Credential $Credential `
                    -ErrorAction Stop | Out-Null

                $ServerBack = $true
                Write-Output "WinRM available after reboot. Attempt: $Attempt"
                break
            }
            catch {
                Write-Output "Waiting for WinRM... Attempt $Attempt of 30"
            }
        }

        if (-not $ServerBack) {
            throw "Target server did not become available through WinRM within the reboot timeout."
        }

        Write-Output "Creating new remote PowerShell session..."

        $Session = New-PSSession `
            -ComputerName $ComputerName `
            -Authentication Negotiate `
            -Credential $Credential `
            -ErrorAction Stop

        Write-Output "Remote session re-established: SUCCESS"
    }

    # --------------------------------------------------------
    # Verify all prerequisites
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Verifying DDC Prerequisites"
    Write-Output "============================================================"

    $Verification = Invoke-Command `
        -Session $Session `
        -ScriptBlock {
            param($Features)

            Get-WindowsFeature -Name $Features |
                Select-Object Name, InstallState

        } `
        -ArgumentList (,$FeatureNames) `
        -ErrorAction Stop

    $Verification |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    $Missing = $Verification | Where-Object {
        $_.InstallState -ne "Installed"
    }

    if ($Missing) {
        throw "DDC prerequisites are missing: $($Missing.Name -join ', ')"
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "CITRIX DDC PART 1 COMPLETED SUCCESSFULLY"
    Write-Output "============================================================"
}
finally {

    if ($null -ne $Session) {

        Write-Output ""
        Write-Output "Closing remote PowerShell session..."

        Remove-PSSession `
            -Session $Session `
            -ErrorAction SilentlyContinue

        Write-Output "Remote session closed."
    }
}
