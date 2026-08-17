#===========================================================================
# Test-HybridWorkerConnectivity.ps1
#
# Tests connectivity and prerequisites from the Hybrid Worker to a target.
#===========================================================================

$TargetComputerName = Get-AutomationVariable -Name "ValidationComputerName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TargetComputerName)) { throw "Automation variable 'ValidationComputerName' is missing." }
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) { throw "Automation variable 'CitrixCredentialSecretName' is missing." }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "Automation variable 'KeyVaultName' is missing." }

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

$Secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $CredentialSecretName -AsPlainText -ErrorAction Stop
$Data = $Secret | ConvertFrom-Json
$SecurePassword = ConvertTo-SecureString $Data.Password -AsPlainText -Force
$Credential = [PSCredential]::new($Data.Username, $SecurePassword)

Write-Output "Testing DNS..."
Resolve-DnsName $TargetComputerName -ErrorAction Stop | Out-Null
Write-Output "DNS: OK"

Write-Output "Testing WinRM..."
Test-WSMan -ComputerName $TargetComputerName -Credential $Credential -ErrorAction Stop | Out-Null
Write-Output "WinRM: OK"

Write-Output "Testing remote PowerShell..."
Invoke-Command -ComputerName $TargetComputerName -Credential $Credential -ErrorAction Stop -ScriptBlock {
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        PowerShell = $PSVersionTable.PSVersion.ToString()
        Time = Get-Date
    }
}

Write-Output "Hybrid Worker connectivity test completed successfully."
