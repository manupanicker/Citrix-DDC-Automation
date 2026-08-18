$ErrorActionPreference = "Continue"

Write-Output "============================================================"
Write-Output "Citrix License Server Installation"
Write-Output "============================================================"

# ------------------------------------------------------------
# Automation variables
# ------------------------------------------------------------

$ComputerName = Get-AutomationVariable -Name "LicenseServerComputerName"
$Source = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

Write-Output "Target Server : $ComputerName"
Write-Output "UNC Source    : $Source"
Write-Output "Key Vault     : $KeyVaultName"
Write-Output "Secret Name   : $CredentialSecretName"

# ------------------------------------------------------------
# Azure modules
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Loading Azure PowerShell modules"
Write-Output "============================================================"

Import-Module Az.Accounts -Force -ErrorAction Stop
Write-Output "Az.Accounts : $((Get-Module Az.Accounts).Version)"

Import-Module Az.KeyVault -Force -ErrorAction Stop
Write-Output "Az.KeyVault : $((Get-Module Az.KeyVault).Version)"

# ------------------------------------------------------------
# Azure authentication
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Connecting to Azure"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

Write-Output "Azure authentication: SUCCESS"

# ------------------------------------------------------------
# Key Vault using Managed Identity REST API
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

$SecretUri = "{0}/secrets/{1}?api-version=7.4" -f `
    $VaultUri,
    $CredentialSecretName

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
# Process credential
# ------------------------------------------------------------

Write-Output ""
Write-Output "Processing credential..."

$CredentialData = $SecretResponse.value | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) {
    throw "Username is missing from Key Vault secret."
}

if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) {
    throw "Password is missing from Key Vault secret."
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
# WinRM
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

try {

    # --------------------------------------------------------
    # Paths
    # --------------------------------------------------------

    $RemoteRoot = "C:\Source\CVAD"
    $RemoteInstaller = "C:\Source\CVAD\x64\Licensing\CitrixLicensing.exe"

    # --------------------------------------------------------
    # Check whether package already exists
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Checking for existing Citrix package"
    Write-Output "============================================================"

    $PackageExists = Invoke-Command -Session $Session -ScriptBlock {
        param($InstallerPath)

        Test-Path $InstallerPath

    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    if ($PackageExists) {

        Write-Output "Existing package found."
        Write-Output "Installer already exists:"
        Write-Output $RemoteInstaller
        Write-Output ""
        Write-Output "Skipping package copy."

    }
    else {

        # ----------------------------------------------------
        # Create destination folder
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "Package not found."
        Write-Output "Creating destination folder..."

        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)

            New-Item `
                -Path $Path `
                -ItemType Directory `
                -Force |
                Out-Null

            Write-Output "$Path ready."

        } -ArgumentList $RemoteRoot -ErrorAction Stop

        # ----------------------------------------------------
        # Copy package
        # UNC -> Hybrid Worker -> Remote target
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Copying Citrix package"
        Write-Output "============================================================"

        Write-Output "Source:"
        Write-Output $Source

        Write-Output ""
        Write-Output "Destination:"
        Write-Output $RemoteRoot

        Copy-Item `
            -Path "$Source\*" `
            -Destination $RemoteRoot `
            -ToSession $Session `
            -Recurse `
            -Force `
            -ErrorAction Stop `
            -Verbose

        Write-Output ""
        Write-Output "Package copy: SUCCESS"
    }

    # --------------------------------------------------------
    # Verify installer
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Verifying Citrix Licensing installer"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {
        param($InstallerPath)

        if (-not (Test-Path $InstallerPath)) {
            throw "CitrixLicensing.exe was not found at $InstallerPath"
        }

        $File = Get-Item $InstallerPath

        Write-Output "Installer found."
        Write-Output "Path : $($File.FullName)"
        Write-Output "Size : $($File.Length) bytes"

    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    Write-Output "Installer verification: SUCCESS"

    # --------------------------------------------------------
    # INSTALL CITRIX LICENSE SERVER
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Installing Citrix License Server"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {

        $ErrorActionPreference = "Stop"

        $Installer = "C:\Source\CVAD\x64\Licensing\CitrixLicensing.exe"
        $LogDirectory = "C:\Temp"
        $LogFile = "C:\Temp\CitrixLicenseInstall.log"

        if (-not (Test-Path $Installer)) {
            throw "Citrix License Server installer not found: $Installer"
        }

        New-Item `
            -Path $LogDirectory `
            -ItemType Directory `
            -Force |
            Out-Null

        # ----------------------------------------------------
        # Check whether already installed
        # ----------------------------------------------------

        $ExistingServices = Get-Service `
            -Name "Citrix Licensing" `
            -ErrorAction SilentlyContinue

        if ($ExistingServices) {

            Write-Output "Citrix Licensing service already exists."
            Write-Output "Installation appears to already be present."

        }
        else {

            Write-Output "Starting Citrix License Server installer..."
            Write-Output "Installer : $Installer"
            Write-Output "Log       : $LogFile"

            $Process = Start-Process `
                -FilePath $Installer `
                -ArgumentList "/quiet /l `"$LogFile`" CEIPOPTIN=NONE" `
                -Wait `
                -PassThru

            $ExitCode = $Process.ExitCode

            Write-Output "Installer Exit Code : $ExitCode"

            if ($ExitCode -notin @(0,3010,1641)) {

                throw "Citrix License Server installation failed with exit code $ExitCode. Check $LogFile"
            }

            if ($ExitCode -eq 3010) {
                Write-Output "Installer completed successfully. Reboot required."
            }
            elseif ($ExitCode -eq 1641) {
                Write-Output "Installer completed successfully and initiated a reboot."
            }
            else {
                Write-Output "Installer completed successfully."
            }
        }

    } -ErrorAction Stop

    # --------------------------------------------------------
    # Validate Citrix Licensing services
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Validating Citrix Licensing services"
    Write-Output "============================================================"

    $Services = Invoke-Command -Session $Session -ScriptBlock {

        $ServiceNames = @(
            "Citrix Licensing",
            "CitrixWebServicesforLicensing",
            "CitrixLicensingSupportService"
        )

        Get-Service `
            -Name $ServiceNames `
            -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType

    } -ErrorAction Stop

    if (-not $Services) {
        throw "No Citrix Licensing services were found after installation."
    }

    $Services | Format-Table -AutoSize | Out-String | Write-Output

    Write-Output ""
    Write-Output "Citrix Licensing services detected."

    # --------------------------------------------------------
    # Start stopped services
    # --------------------------------------------------------

    Invoke-Command -Session $Session -ScriptBlock {

        $ServiceNames = @(
            "Citrix Licensing",
            "CitrixWebServicesforLicensing",
            "CitrixLicensingSupportService"
        )

        foreach ($Name in $ServiceNames) {

            $Service = Get-Service `
                -Name $Name `
                -ErrorAction SilentlyContinue

            if ($null -ne $Service) {

                if ($Service.Status -ne "Running") {

                    Write-Output "Starting service: $Name"

                    Start-Service `
                        -Name $Name `
                        -ErrorAction SilentlyContinue

                    Start-Sleep -Seconds 3
                }
            }
        }

    } -ErrorAction Stop

    # --------------------------------------------------------
    # Final service validation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Final Citrix Licensing service status"
    Write-Output "============================================================"

    $FinalServices = Invoke-Command -Session $Session -ScriptBlock {

        Get-Service `
            -Name "Citrix Licensing","CitrixWebServicesforLicensing","CitrixLicensingSupportService" `
            -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType

    } -ErrorAction Stop

    $FinalServices | Format-Table -AutoSize | Out-String | Write-Output

    # --------------------------------------------------------
    # Cleanup package
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Cleaning up installation package"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {

        $Path = "C:\Source\CVAD"

        if (Test-Path $Path) {

            Remove-Item `
                -Path $Path `
                -Recurse `
                -Force `
                -ErrorAction Stop

            Write-Output "Removed $Path"

        }
        else {

            Write-Output "$Path does not exist. Nothing to remove."

        }

    } -ErrorAction Stop

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "CITRIX LICENSE SERVER INSTALLATION COMPLETED"
    Write-Output "============================================================"

}
finally {

    # --------------------------------------------------------
    # Always close remote session
    # --------------------------------------------------------

    if ($null -ne $Session) {

        Write-Output ""
        Write-Output "Closing remote PowerShell session..."

        Remove-PSSession `
            -Session $Session `
            -ErrorAction SilentlyContinue

        Write-Output "Remote session closed."
    }
}
