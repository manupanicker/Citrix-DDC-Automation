$ErrorActionPreference = "Continue"

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller - Part 2"
Write-Output "DDC Component Installation"
Write-Output "============================================================"

# ------------------------------------------------------------
# Automation variables - same as working DDC runbook
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
# Azure modules - same framework as Part 1 / working DDC
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
# Azure authentication
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Connecting to Azure"
Write-Output "============================================================"

Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
Write-Output "Azure authentication: SUCCESS"

# ------------------------------------------------------------
# Key Vault - Managed Identity REST API
# Same mechanism as working DDC runbook
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

Write-Output ""
Write-Output "Creating remote PowerShell session..."

$Session = New-PSSession `
    -ComputerName $ComputerName `
    -Authentication Negotiate `
    -Credential $Credential `
    -ErrorAction Stop

Write-Output "Remote session: SUCCESS"

$RemoteRoot = "C:\Source\CVAD"
$RemoteInstaller = "C:\Source\CVAD\x64\XenDesktop Setup\XenDesktopServerSetup.exe"
$LogDirectory = "C:\Temp"
$LogFile = "C:\Temp\CitrixDDCInstall.log"
$ResultFile = "C:\Temp\CitrixDDCInstall.exitcode"

$RebootCount = 0
$MaxReboots = 6

try {

    # --------------------------------------------------------
    # Pre-flight
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PART 2 PRE-FLIGHT VALIDATION"
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

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            OS = $OS.Caption
            OSBuild = $OS.BuildNumber
            DomainJoined = [bool]$Computer.PartOfDomain
            Domain = $Computer.Domain
            IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
            PendingReboot = $PendingReboot
            FreeSpaceGB = [math]::Round(
                (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2
            )
        }

    } -ErrorAction Stop

    $Preflight | Format-List | Out-String | Write-Output

    if (-not $Preflight.DomainJoined) {
        throw "DDC target is not domain joined."
    }

    if ($Preflight.IsDomainController) {
        throw "DDC installation target is a Domain Controller."
    }

    # --------------------------------------------------------
    # Handle pending reboot before Citrix installation
    # --------------------------------------------------------

    while ($Preflight.PendingReboot) {

        $RebootCount++

        if ($RebootCount -gt $MaxReboots) {
            throw "Maximum automatic reboot limit of $MaxReboots has been reached."
        }

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "PENDING REBOOT DETECTED"
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

        $Preflight.PendingReboot = Invoke-Command -Session $Session -ScriptBlock {

            $Pending = $false

            foreach ($Path in @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            )) {
                if (Test-Path $Path) {
                    $Pending = $true
                }
            }

            $RenameOps = Get-ItemProperty `
                -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
                -Name PendingFileRenameOperations `
                -ErrorAction SilentlyContinue

            if ($RenameOps) {
                $Pending = $true
            }

            $Pending

        } -ErrorAction Stop

        if ($Preflight.PendingReboot) {
            Write-Output "Pending reboot remains. Another reboot will be attempted."
        }
        else {
            Write-Output "Pending reboot cleared successfully."
        }
    }

    Write-Output "DDC Part 2 pre-flight validation: SUCCESS"

    # --------------------------------------------------------
    # Stage Citrix DDC package on target
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Checking for existing Citrix DDC package"
    Write-Output "============================================================"

    $PackageReady = Invoke-Command -Session $Session -ScriptBlock {

        param($InstallerPath)

        Test-Path -LiteralPath $InstallerPath -PathType Leaf

    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    if ($PackageReady) {
        Write-Output "Existing Citrix DDC package found on target."
        Write-Output "Installer already exists:"
        Write-Output $RemoteInstaller
        Write-Output "Skipping package copy."
    }
    else {

        Write-Output "Package not found on target."
        Write-Output "Source:"
        Write-Output $Source
        Write-Output "Destination:"
        Write-Output $RemoteRoot
        Write-Output ""
        Write-Output "Creating destination folder..."

        Invoke-Command -Session $Session -ScriptBlock {
            param($Destination)

            New-Item -Path $Destination -ItemType Directory -Force | Out-Null

        } -ArgumentList $RemoteRoot -ErrorAction Stop

        Write-Output "$RemoteRoot ready."

        Write-Output ""
        Write-Output "Copying Citrix DDC package"
        Write-Output ""

        try {
            Invoke-Command -Session $Session -ScriptBlock {

                param($SourcePath, $DestinationPath)

                if (-not (Test-Path -LiteralPath $SourcePath)) {
                    throw "Citrix source package path is not accessible from target: $SourcePath"
                }

                $SourceItem = Get-Item -LiteralPath $SourcePath -ErrorAction Stop

                if (-not $SourceItem.PSIsContainer) {
                    throw "Citrix source path is not a directory: $SourcePath"
                }

                Copy-Item `
                    -Path (Join-Path $SourcePath '*') `
                    -Destination $DestinationPath `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop

            } -ArgumentList $Source, $RemoteRoot -ErrorAction Stop

            Write-Output "Package copy: SUCCESS"
        }
        catch {
            throw "Citrix DDC package copy failed. Source '$Source' may not be accessible from the target server. Error: $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # Verify Citrix installer
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Verifying Citrix DDC installer"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {

        param($InstallerPath)

        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            throw "Citrix DDC installer was not found at $InstallerPath"
        }

        $File = Get-Item -LiteralPath $InstallerPath

        Write-Output "Installer found."
        Write-Output "Path : $($File.FullName)"
        Write-Output "Size : $($File.Length) bytes"

    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    Write-Output "Installer verification: SUCCESS"

    # --------------------------------------------------------
    # Check existing DDC
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
        # Citrix installer
        #
        # IMPORTANT:
        # Run the proven synchronous Start-Process -Wait pattern
        # inside the remote session. Do NOT create a second
        # launcher/wrapper process.
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Installing Citrix Delivery Controller"
        Write-Output "============================================================"

        $InstallResult = Invoke-Command -Session $Session -ScriptBlock {

            param($Installer, $LogDirectory)

            $ErrorActionPreference = "Stop"

            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

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
            Write-Output "Arguments : $Arguments"
            Write-Output ""
            Write-Output "Starting Citrix Delivery Controller installer..."
            Write-Output "The remote command will wait for the installer to finish."

            $Process = Start-Process `
                -FilePath $Installer `
                -ArgumentList $Arguments `
                -PassThru

            Write-Output "Citrix installer process started."
            Write-Output "Process ID : $($Process.Id)"

            $Process.WaitForExit()

            [pscustomobject]@{
                ProcessId = $Process.Id
                ExitCode = $Process.ExitCode
            }

        } -ArgumentList $RemoteInstaller, $LogDirectory -ErrorAction Stop

        Write-Output ""
        Write-Output "Citrix installer completed."
        Write-Output "Process ID : $($InstallResult.ProcessId)"
        Write-Output "Exit Code  : $($InstallResult.ExitCode)"

        $ExitCode = [int]$InstallResult.ExitCode

        if ($ExitCode -notin @(0, 3, 3010, 1641)) {
            throw "Citrix Delivery Controller installation failed with exit code $ExitCode. Check $LogDirectory on the target server."
        }

        if ($ExitCode -eq 3) {
            Write-Output "Citrix installer returned expected code 3."
        }
        elseif ($ExitCode -eq 3010) {

            $RebootCount++

            if ($RebootCount -gt $MaxReboots) {
                throw "Citrix installer requires a reboot, but maximum automatic reboot limit of $MaxReboots has been reached."
            }

            Write-Output "Citrix installer completed and requires a reboot."
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
        }
        elseif ($ExitCode -eq 1641) {

            $RebootCount++

            if ($RebootCount -gt $MaxReboots) {
                throw "Citrix installer initiated a reboot, but maximum automatic reboot limit of $MaxReboots has been reached."
            }

            Write-Output "Citrix installer initiated a reboot."
            Write-Output "Automatic reboot: $RebootCount of $MaxReboots"

            Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
            $Session = $null
        }
        else {
            Write-Output "Citrix installer completed successfully without requesting a reboot."
        }
    }

    # --------------------------------------------------------
    # Reconnect after Citrix reboot
    # --------------------------------------------------------

    if ($null -eq $Session) {

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Waiting for target server after reboot"
        Write-Output "============================================================"

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
    # Validate DDC installation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Validating Citrix Delivery Controller installation"
    Write-Output "============================================================"

    $ServiceNames = @(
        "CitrixBrokerService",
        "CitrixConfigurationLogging",
        "CitrixHostService",
        "CitrixMachineCreationService",
        "CitrixMonitor"
    )

    $ServiceWaitSeconds = 300
    $ServicePollSeconds = 15
    $ElapsedSeconds = 0

    while ($ElapsedSeconds -lt $ServiceWaitSeconds) {

        $Services = Invoke-Command -Session $Session -ScriptBlock {
            param($Names)

            foreach ($Name in $Names) {
                Get-Service -Name $Name -ErrorAction SilentlyContinue
            }

        } -ArgumentList (,$ServiceNames) -ErrorAction Stop

        $MissingServices = $ServiceNames | Where-Object {
            $_ -notin $Services.Name
        }

        if (-not $MissingServices) {
            break
        }

        Write-Output "Waiting for Citrix services to initialize..."
        Write-Output "Missing services: $($MissingServices -join ', ')"
        Write-Output "Elapsed: $ElapsedSeconds seconds of $ServiceWaitSeconds"

        Start-Sleep -Seconds $ServicePollSeconds
        $ElapsedSeconds += $ServicePollSeconds
    }

    if (-not $Services) {
        throw "No expected Citrix Delivery Controller services were found after installation. Check $LogDirectory on the target server."
    }

    $Services |
        Select-Object Name, Status, StartType |
        Sort-Object Name |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    $MissingServices = $ServiceNames | Where-Object {
        $_ -notin $Services.Name
    }

    if ($MissingServices) {
        throw "Expected Citrix Delivery Controller services are missing after waiting $ServiceWaitSeconds seconds: $($MissingServices -join ', ')"
    }

    foreach ($Service in $Services) {

        if ($Service.Status -ne "Running") {

            Write-Output "Starting service: $($Service.Name)"

            Invoke-Command -Session $Session -ScriptBlock {
                param($Name)
                Start-Service -Name $Name -ErrorAction Stop
            } -ArgumentList $Service.Name -ErrorAction Stop
        }
    }

    Start-Sleep -Seconds 5

    $FinalServices = Invoke-Command -Session $Session -ScriptBlock {
        param($Names)

        foreach ($Name in $Names) {
            Get-Service -Name $Name -ErrorAction SilentlyContinue
        }

    } -ArgumentList (,$ServiceNames) -ErrorAction Stop

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Final Citrix Delivery Controller service status"
    Write-Output "============================================================"

    $FinalServices |
        Select-Object Name, Status, StartType |
        Sort-Object Name |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    $StoppedServices = $FinalServices | Where-Object {
        $_.Status -ne "Running"
    }

    if ($StoppedServices) {
        throw "One or more required Citrix Delivery Controller services are not running: $($StoppedServices.Name -join ', ')"
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "CITRIX DELIVERY CONTROLLER PART 2 COMPLETED SUCCESSFULLY"
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
