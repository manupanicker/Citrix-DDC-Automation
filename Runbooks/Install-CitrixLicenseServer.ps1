#===========================================================================
# Install Citrix License Server Remotely using WinRM (WSMan)
# Target: Citrix Virtual Apps and Desktops 7 2507 LTSR CU1
#===========================================================================

$ComputerName = Get-AutomationVariable -Name "LicenseServerComputerName"
$Source       = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

$ErrorActionPreference = "Stop"

Write-Output "============================================================"
Write-Output "Citrix License Server Installation"
Write-Output "============================================================"
Write-Output "Target Server : $ComputerName"
Write-Output "Source        : $Source"
Write-Output "Key Vault     : $KeyVaultName"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

$Secret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $CredentialSecretName -AsPlainText -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($Secret)) { throw "Key Vault secret '$CredentialSecretName' is empty." }

$CredentialData = $Secret | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) { throw "Username is missing from Key Vault secret '$CredentialSecretName'." }
if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) { throw "Password is missing from Key Vault secret '$CredentialSecretName'." }

$SecurePassword = ConvertTo-SecureString $CredentialData.Password -AsPlainText -Force
$Credential = [PSCredential]::new($CredentialData.Username, $SecurePassword)

Write-Output "Testing WinRM connectivity to $ComputerName..."
Test-WSMan -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop | Out-Null
Write-Output "WinRM connectivity successful."

Invoke-Command -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop -ScriptBlock {
    param([string]$Source)

    $ErrorActionPreference = "Stop"
    $Installer = Join-Path $Source "x64\Licensing\CitrixLicensing.exe"
    $LogFile = "C:\Temp\CitrixLicenseInstall.log"

    New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null

    if (-not (Test-Path $Installer)) { throw "Installer not found: $Installer" }

    if (Get-Service -Name "Citrix Licensing" -ErrorAction SilentlyContinue) {
        Write-Output "Citrix License Server already installed on this host."
        Get-Service "Citrix Licensing","CitrixWebServicesforLicensing","CitrixLicensingSupportService" -ErrorAction SilentlyContinue |
            Format-Table Name, Status, StartType
        return
    }

    Write-Output "Installing Citrix License Server..."
    $Process = Start-Process -FilePath $Installer -ArgumentList "/quiet /l `"$LogFile`" CEIPOPTIN=NONE" -Wait -PassThru
    $ExitCode = $Process.ExitCode
    Write-Output "Exit Code : $ExitCode"

    if ($ExitCode -notin 0,3010,1641) {
        throw "Citrix License Server installation failed with exit code $ExitCode. Check log: $LogFile"
    }

    $Services = Get-Service -Name "Citrix Licensing","CitrixWebServicesforLicensing","CitrixLicensingSupportService" -ErrorAction SilentlyContinue
    if (-not $Services -or $Services.Count -lt 1) {
        throw "Installer returned success but Citrix Licensing services are missing. Check log: $LogFile"
    }

    $Services | Where-Object { $_.Status -ne 'Running' } | ForEach-Object {
        Write-Output "Starting service: $($_.Name)"
        Start-Service -Name $_.Name -ErrorAction SilentlyContinue
    }

    Write-Output ""
    Write-Output "Installation Successful"
    Get-Service "Citrix Licensing","CitrixWebServicesforLicensing","CitrixLicensingSupportService" -ErrorAction SilentlyContinue |
        Format-Table Name, Status, StartType

    if ($ExitCode -eq 3010) { Write-Output "NOTE: Reboot required to complete installation." }

    Write-Output "Listening ports:"
    Get-NetTCPConnection -State Listen -LocalPort 27000,7279,8082,8083 -ErrorAction SilentlyContinue |
        Select-Object LocalAddress, LocalPort | Sort-Object LocalPort | Format-Table

} -ArgumentList $Source

Write-Output "Citrix License Server runbook completed successfully."
