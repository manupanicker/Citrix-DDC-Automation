$ErrorActionPreference = "Stop"

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller - Part 2"
Write-Output "DDC Component Installation"
Write-Output "============================================================"

# ------------------------------------------------------------
# Automation variables - same as existing DDC/Licensing
# ------------------------------------------------------------

$ComputerName = Get-AutomationVariable -Name "DDCComputerName"
$Source = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

if ([string]::IsNullOrWhiteSpace($ComputerName)) {
    throw "Automation variable 'DDCComputerName' is empty or does not exist."
}
if ([string]::IsNullOrWhiteSpace($Source)) {
    throw "Automation variable 'CitrixMediaPath' is empty or does not exist."
}
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) {
    throw "Automation variable 'KeyVaultName' is empty or does not exist."
}
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) {
    throw "Automation variable 'CitrixCredentialSecretName' is empty or does not exist."
}

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
# Key Vault - same method as existing DDC/Licensing automation
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
# Process credential
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

$MaxReboots = 6
$RebootCount = 0

try {

    # --------------------------------------------------------
    # Paths - same remote location used by existing automation
    # --------------------------------------------------------

    $RemoteRoot = "C:\Source\CVAD"
    $RemoteInstaller = "C:\Source\CVAD\x64\XenDesktop Setup\XenDesktopServerSetup.exe"
    $LogDirectory = "C:\Logs"
    $LogFile = "C:\Logs\CitrixDDCInstall.log"

    # --------------------------------------------------------
    # Target pre-flight
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PART 2 PRE-FLIGHT"
    Write-Output "============================================================"

    $Preflight = Invoke-Command -Session $Session -ScriptBlock {

        $OS = Get-CimInstance Win32_OperatingSystem
        $Computer = Get-CimInstance Win32_ComputerSystem

        $PendingReboot = $false

        $PendingPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        )

        foreach ($Path in $PendingPaths) {
            if (Test-Path $Path) {
                $PendingReboot = $true
            }
        }

        $CBSReboot = Get-ItemProperty `
            -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue

        if ($CBSReboot) {
            $PendingReboot = $true
        }

        $Volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            OS = $OS.Caption
            OSBuild = $OS.BuildNumber
            DomainJoined = [bool]$Computer.PartOfDomain
            Domain = $Computer.Domain
            IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
            PendingReboot = $PendingReboot
            FreeSpaceGB = if ($Volume) { [math]::Round($Volume.FreeSpace / 1GB, 2) } else { $null }
        }

    } -ErrorAction Stop

    $Preflight | Format-List | Out-String | Write-Output

    if (-not $Preflight.DomainJoined) {
        throw "DDC target is not domain joined."
    }

    if ($Preflight.IsDomainController) {
        throw "DDC installation target is a Domain Controller."
    }

    if ($null -eq $Preflight.FreeSpaceGB -or $Preflight.FreeSpaceGB -lt 10) {
        throw "Insufficient free space on C:. At least 10 GB is required."
    }

    # --------------------------------------------------------
    # Handle an existing pending reboot before DDC installation
    # --------------------------------------------------------

    while ($Preflight.PendingReboot) {

        $RebootCount++

        if ($RebootCount -gt $MaxReboots) {
            throw "Maximum automatic reboot limit of $MaxReboots reached."
        }

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "PENDING REBOOT DETECTED"
        Write-Output "============================================================"
        Write-Output "Automatic reboot: $RebootCount of $MaxReboots"

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

        $Session = New-PSSession `
            -ComputerName $ComputerName `
            -Authentication Negotiate `
            -Credential $Credential `
            -ErrorAction Stop

        $Preflight.PendingReboot = Invoke-Command -Session $Session -ScriptBlock {

            $PendingReboot = $false

            $PendingPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            )

            foreach ($Path in $PendingPaths) {
                if (Test-Path $Path) {
                    $PendingReboot = $true
                }
            }

            $CBSReboot = Get-ItemProperty `
                -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
                -Name PendingFileRenameOperations `
                -ErrorAction SilentlyContinue

            if ($CBSReboot) {
                $PendingReboot = $true
            }

            $PendingReboot

        } -ErrorAction Stop
    }

    # --------------------------------------------------------
    # Check/copy Citrix package
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Checking Citrix DDC package"
    Write-Output "============================================================"

    $PackageExists = Invoke-Command -Session $Session -ScriptBlock {
        param($InstallerPath)
        Test-Path -LiteralPath $InstallerPath
    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    if ($PackageExists) {

        Write-Output "Existing package found."
        Write-Output "Installer already exists:"
        Write-Output $RemoteInstaller
        Write-Output "Skipping package copy."

    }
    else {

        Write-Output "Package not found."
        Write-Output "Creating destination folder..."

        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            Write-Output "$Path ready."
        } -ArgumentList $RemoteRoot -ErrorAction Stop

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Copying Citrix DDC package"
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
            -ErrorAction Stop

        Write-Output "Package copy: SUCCESS"
    }

    # --------------------------------------------------------
    # Verify installer
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Verifying Citrix DDC installer"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {
        param($InstallerPath)

        if (-not (Test-Path -LiteralPath $InstallerPath)) {
            throw "Citrix DDC installer was not found at $InstallerPath"
        }

        $File = Get-Item -LiteralPath $InstallerPath

        Write-Output "Installer found."
        Write-Output "Path : $($File.FullName)"
        Write-Output "Size : $($File.Length) bytes"

    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    Write-Output "Installer verification: SUCCESS"

    # --------------------------------------------------------
    # Check whether DDC is already installed
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "Checking existing Delivery Controller installation..."

    $ExistingDDC = Invoke-Command -Session $Session -ScriptBlock {
        [bool](Get-Service -Name "CitrixBrokerService" -ErrorAction SilentlyContinue)
    } -ErrorAction Stop

    if ($ExistingDDC) {

        Write-Output "Citrix Delivery Controller service already exists."
        Write-Output "Installation appears to already be present."

    }
    else {

        # ----------------------------------------------------
        # Install DDC
        # Exact arguments from supplied YAML
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Installing Citrix Delivery Controller"
        Write-Output "============================================================"

        $InstallResult = Invoke-Command -Session $Session -ScriptBlock {

            param($Installer, $LogDirectory, $LogFile)

            $ErrorActionPreference = "Stop"

            New-Item `
                -Path $LogDirectory `
                -ItemType Directory `
                -Force |
                Out-Null

            $Arguments = @(
                "/components controller,desktopstudio"
                "/configure_firewall"
                "/nosql"
                "/disableexperiencemetrics"
                "/noreboot"
                "/quiet"
                "/logpath `"$LogDirectory`""
                "/IGNORE_HW_CHECK_FAILURE"
            ) -join " "

            Write-Output "Installer : $Installer"
            Write-Output "Log       : $LogDirectory"
            Write-Output "Arguments : $Arguments"

            $Process = Start-Process `
                -FilePath $Installer `
                -ArgumentList $Arguments `
                -Wait `
                -PassThru

            [pscustomobject]@{
                ExitCode = $Process.ExitCode
                ProcessId = $Process.Id
                LogFile = $LogFile
            }

        } -ArgumentList $RemoteInstaller, $LogDirectory, $LogFile -ErrorAction Stop

        $ExitCode = [int]$InstallResult.ExitCode

        Write-Output "Citrix installer process ID : $($InstallResult.ProcessId)"
        Write-Output "Citrix installer exit code   : $ExitCode"

        if ($ExitCode -notin @(0,3,3010)) {
            throw "Citrix Delivery Controller installation failed with exit code $ExitCode. Check $LogFile on the target server."
        }

        if ($ExitCode -eq 3010) {
            Write-Output "Citrix installer completed and reports reboot required."
        }
        elseif ($ExitCode -eq 3) {
            Write-Output "Citrix installer returned expected code 3."
        }
        else {
            Write-Output "Citrix installer completed successfully."
        }

        # ----------------------------------------------------
        # Reboot after DDC installation when installation
        # changed the machine, matching the supplied YAML.
        # No RunOnce/resume logic is included in Part 2.
        # ----------------------------------------------------

        $RebootRequired = ($ExitCode -eq 3010)

        if ($RebootRequired) {

            $RebootCount++

            if ($RebootCount -gt $MaxReboots) {
                throw "Maximum automatic reboot limit of $MaxReboots reached."
            }

            Write-Output ""
            Write-Output "============================================================"
            Write-Output "REBOOT AFTER DDC INSTALLATION"
            Write-Output "============================================================"
            Write-Output "Automatic reboot: $RebootCount of $MaxReboots"

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

            $Session = New-PSSession `
                -ComputerName $ComputerName `
                -Authentication Negotiate `
                -Credential $Credential `
                -ErrorAction Stop

            Write-Output "Remote session re-established: SUCCESS"
        }
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PART 2 INSTALLATION COMPLETED"
    Write-Output "============================================================"

}
finally {

    if ($null -ne $Session) {
        Write-Output ""
        Write-Output "Closing remote PowerShell session..."
        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
        Write-Output "Remote session closed."
    }
}
