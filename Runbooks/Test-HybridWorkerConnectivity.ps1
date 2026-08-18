#===========================================================================
# Test-HybridWorkerConnectivity.ps1
#
# Purpose:
#   Validate Azure Automation Hybrid Worker connectivity to a target machine.
#
# Tests:
#   1. Required Az modules
#   2. Automation variables
#   3. Managed Identity authentication
#   4. Key Vault secret retrieval
#   5. DNS resolution
#   6. WinRM using Negotiate
#   7. Remote PowerShell using Negotiate
#===========================================================================

$ErrorActionPreference = "Stop"

Write-Output "============================================================"
Write-Output "Hybrid Worker Connectivity Test"
Write-Output "============================================================"

#---------------------------------------------------------------------------
# 1. PowerShell environment
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "PowerShell environment:"
Write-Output "PowerShell Version : $($PSVersionTable.PSVersion)"
Write-Output "PowerShell Edition  : $($PSVersionTable.PSEdition)"
Write-Output "CLR Version         : $($PSVersionTable.CLRVersion)"
Write-Output "Computer Name       : $env:COMPUTERNAME"

#---------------------------------------------------------------------------
# 2. Load required Azure modules
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Loading Azure PowerShell modules"
Write-Output "============================================================"

try {

    Import-Module Az.Accounts -Force -ErrorAction Stop
    Write-Output "Az.Accounts loaded successfully."

    Import-Module Az.KeyVault -Force -ErrorAction Stop
    Write-Output "Az.KeyVault loaded successfully."

}
catch {

    Write-Output ""
    Write-Output "FAILED while loading Azure PowerShell modules."
    Write-Output $_.Exception.ToString()

    throw
}

$AccountsModule = Get-Module Az.Accounts
$KeyVaultModule = Get-Module Az.KeyVault

Write-Output ""
Write-Output "Loaded module versions:"
Write-Output "Az.Accounts : $($AccountsModule.Version)"
Write-Output "Az.KeyVault : $($KeyVaultModule.Version)"

Write-Output ""
Write-Output "Module paths:"
Write-Output "Az.Accounts : $($AccountsModule.Path)"
Write-Output "Az.KeyVault : $($KeyVaultModule.Path)"

#---------------------------------------------------------------------------
# 3. Read Automation variables
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Reading Automation variables"
Write-Output "============================================================"

try {

    $TargetComputerName = Get-AutomationVariable `
        -Name "ValidationComputerName"

    $CredentialSecretName = Get-AutomationVariable `
        -Name "CitrixCredentialSecretName"

    $KeyVaultName = Get-AutomationVariable `
        -Name "KeyVaultName"

}
catch {

    Write-Output ""
    Write-Output "FAILED while reading Automation variables."
    Write-Output $_.Exception.ToString()

    throw
}

if ([string]::IsNullOrWhiteSpace($TargetComputerName)) {
    throw "Automation variable 'ValidationComputerName' is missing."
}

if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) {
    throw "Automation variable 'CitrixCredentialSecretName' is missing."
}

if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    throw "Automation variable 'KeyVaultName' is missing."
}

Write-Output "Target computer : $TargetComputerName"
Write-Output "Key Vault       : $KeyVaultName"
Write-Output "Secret name     : $CredentialSecretName"

#---------------------------------------------------------------------------
# 4. Connect to Azure using Hybrid Worker Managed Identity
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Connecting to Azure using Managed Identity"
Write-Output "============================================================"

try {

    $AzContext = Connect-AzAccount `
        -Identity `
        -ErrorAction Stop

    Write-Output "Azure authentication: OK"

    if ($null -ne $AzContext.Context) {

        Write-Output "Subscription Name : $($AzContext.Context.Subscription.Name)"
        Write-Output "Subscription ID   : $($AzContext.Context.Subscription.Id)"
        Write-Output "Tenant ID         : $($AzContext.Context.Tenant.Id)"

    }

}
catch {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "FAILED: Connect-AzAccount"
    Write-Output "============================================================"

    Write-Output ""
    Write-Output "Exception:"
    Write-Output $_.Exception.ToString()

    Write-Output ""
    Write-Output "Command:"
    Write-Output $_.InvocationInfo.Line

    throw
}

#---------------------------------------------------------------------------
# 5. Retrieve Key Vault secret
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Retrieving credential from Key Vault"
Write-Output "============================================================"

try {

    $Secret = Get-AzKeyVaultSecret `
        -VaultName $KeyVaultName `
        -Name $CredentialSecretName `
        -AsPlainText `
        -ErrorAction Stop

}
catch {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "FAILED: Get-AzKeyVaultSecret"
    Write-Output "============================================================"

    Write-Output ""
    Write-Output "Exception:"
    Write-Output $_.Exception.ToString()

    throw
}

if ([string]::IsNullOrWhiteSpace($Secret)) {
    throw "Key Vault returned an empty secret."
}

Write-Output "Key Vault retrieval: OK"

#---------------------------------------------------------------------------
# 6. Parse credential
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "Processing credential..."

try {

    $Data = $Secret | ConvertFrom-Json

}
catch {

    throw "Key Vault secret is not valid JSON. Error: $($_.Exception.Message)"
}

if ([string]::IsNullOrWhiteSpace($Data.Username)) {
    throw "Key Vault secret does not contain 'Username'."
}

if ([string]::IsNullOrWhiteSpace($Data.Password)) {
    throw "Key Vault secret does not contain 'Password'."
}

$SecurePassword = ConvertTo-SecureString `
    $Data.Password `
    -AsPlainText `
    -Force

$Credential = New-Object System.Management.Automation.PSCredential(
    $Data.Username,
    $SecurePassword
)

Write-Output "Credential loaded successfully."
Write-Output "Username: $($Data.Username)"

# IMPORTANT:
# Do NOT output $Data.Password.

#---------------------------------------------------------------------------
# 7. DNS test
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Testing DNS"
Write-Output "============================================================"

try {

    $DnsResult = Resolve-DnsName `
        -Name $TargetComputerName `
        -ErrorAction Stop

    Write-Output "DNS: OK"

    $DnsResult |
        Where-Object {
            $_.IPAddress
        } |
        Select-Object Name,IPAddress |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

}
catch {

    Write-Output ""
    Write-Output "FAILED: DNS resolution"
    Write-Output $_.Exception.ToString()

    throw
}

#---------------------------------------------------------------------------
# 8. WinRM test
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Testing WinRM"
Write-Output "============================================================"

Write-Output "Target       : $TargetComputerName"
Write-Output "Authentication: Negotiate"

try {

    Test-WSMan `
        -ComputerName $TargetComputerName `
        -Authentication Negotiate `
        -Credential $Credential `
        -ErrorAction Stop |
        Out-Null

    Write-Output "WinRM: OK"

}
catch {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "FAILED: Test-WSMan"
    Write-Output "============================================================"

    Write-Output ""
    Write-Output "Exception:"
    Write-Output $_.Exception.ToString()

    throw
}

#---------------------------------------------------------------------------
# 9. Remote PowerShell test
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Testing Remote PowerShell"
Write-Output "============================================================"

try {

    $RemoteResult = Invoke-Command `
        -ComputerName $TargetComputerName `
        -Authentication Negotiate `
        -Credential $Credential `
        -ErrorAction Stop `
        -ScriptBlock {

            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                PowerShell   = $PSVersionTable.PSVersion.ToString()
                PSEdition    = $PSVersionTable.PSEdition
                User         = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                Time         = Get-Date
            }

        }

    Write-Output "Remote PowerShell: OK"

    Write-Output ""
    Write-Output "Remote system information:"

    $RemoteResult |
        Format-List |
        Out-String |
        Write-Output

}
catch {

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "FAILED: Invoke-Command"
    Write-Output "============================================================"

    Write-Output ""
    Write-Output "Exception:"
    Write-Output $_.Exception.ToString()

    throw
}

#---------------------------------------------------------------------------
# 10. Final result
#---------------------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "SUCCESS"
Write-Output "============================================================"

Write-Output "Hybrid Worker connectivity test completed successfully."
Write-Output ""
Write-Output "Target: $TargetComputerName"
Write-Output "Credential: $($Data.Username)"
Write-Output "Key Vault: $KeyVaultName"
