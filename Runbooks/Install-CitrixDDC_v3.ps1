$ErrorActionPreference = "Continue"

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller Installation"
Write-Output "============================================================"

# ------------------------------------------------------------
# Automation variables
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
# WinRM connectivity
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

    $RemoteRoot = "C:\Source\CVAD"
    $RemoteInstaller = "C:\Source\CVAD\x64\XenDesktop Setup\XenDesktopServerSetup.exe"
    $LogDirectory = "C:\Temp"
    $LogFile = "C:\Temp\CitrixDDCInstall.log"
    $ResultFile = "C:\Temp\CitrixDDCInstall.exitcode"

    $RebootCount = 0
    $MaxReboots = 6

    # --------------------------------------------------------
    # Target pre-flight checks
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PRE-FLIGHT VALIDATION"
    Write-Output "============================================================"

    $Preflight = Invoke-Command -Session $Session -ScriptBlock {

        $Result = [ordered]@{}

        $OS = Get-CimInstance Win32_OperatingSystem
        $Computer = Get-CimInstance Win32_ComputerSystem

        $Result.ComputerName = $env:COMPUTERNAME
        $Result.OS = $OS.Caption
        $Result.OSBuild = $OS.BuildNumber
        $Result.DomainJoined = [bool]$Computer.PartOfDomain
        $Result.Domain = $Computer.Domain
        $Result.IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
        $Result.PowerShell = $PSVersionTable.PSVersion.ToString()

        $ReleaseKey = Get-ItemProperty `
            -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" `
            -Name Release `
            -ErrorAction SilentlyContinue

        $Result.DotNetRelease = if ($ReleaseKey) { $ReleaseKey.Release } else { $null }
        $Result.DotNet48OrLater = if ($ReleaseKey) { $ReleaseKey.Release -ge 528040 } else { $false }

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

        $Result.PendingReboot = $PendingReboot

        $Volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $Result.FreeSpaceGB = if ($Volume) { [math]::Round($Volume.FreeSpace / 1GB, 2) } else { $null }

        $Result.VSS = (Get-Service -Name VSS -ErrorAction SilentlyContinue).Status
        $Result.VSSProvider = (Get-Service -Name swprv -ErrorAction SilentlyContinue).Status

        [pscustomobject]$Result

    } -ErrorAction Stop

    $Preflight | Format-List | Out-String | Write-Output

    if (-not $Preflight.DomainJoined) {
        throw "DDC target is not domain joined."
    }

    if ($Preflight.IsDomainController) {
        throw "DDC installation target is a Domain Controller. Citrix Delivery Controller must not be installed on a Domain Controller."
    }

    if (-not $Preflight.DotNet48OrLater) {
        Write-Output "WARNING: .NET Framework 4.8 or later was not detected. The Citrix installer may install the required prerequisite."
    }

    while ($Preflight.PendingReboot) {

        $RebootCount++

        if ($RebootCount -gt $MaxReboots) {
            throw "Maximum automatic reboot limit of $MaxReboots has been reached. Target server still reports a pending reboot."
        }

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "PENDING REBOOT DETECTED"
        Write-Output "============================================================"
        Write-Output "Target server requires a reboot before DDC installation can continue."
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

        $PostRebootPending = Invoke-Command -Session $Session -ScriptBlock {

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

            return $PendingReboot

        } -ErrorAction Stop

        if ($PostRebootPending) {
            Write-Output "Target server still reports a pending reboot."
            Write-Output "Another automatic reboot will be attempted if the $MaxReboots reboot limit has not been reached."
            $Preflight.PendingReboot = $true
        }
        else {
            Write-Output "Pending reboot cleared successfully."
            $Preflight.PendingReboot = $false
        }
    }

    if ($null -eq $Preflight.FreeSpaceGB -or $Preflight.FreeSpaceGB -lt 10) {
        throw "Insufficient free space on C:. At least 10 GB is required for this automated installation staging area."
    }

    Write-Output "DDC pre-flight validation: SUCCESS"

    # --------------------------------------------------------
    # Check whether package already exists
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Checking for existing Citrix DDC package"
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
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Installing Citrix Delivery Controller"
        Write-Output "============================================================"

        $InstallState = Invoke-Command -Session $Session -ScriptBlock {
            param($Installer, $LogDirectory, $ResultFile)

            $ErrorActionPreference = "Stop"

            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

            if (Test-Path -LiteralPath $ResultFile) {
                Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue
            }

            Write-Output "Installer : $Installer"
            Write-Output "Log       : $LogDirectory"
            Write-Output "Result    : $ResultFile"

            $Arguments = @(
                "/components controller,desktopstudio,webstudio,desktopdirector"
                "/nosql"
                "/quiet"
                "/noreboot"
                "/no_pending_reboot_check"
                "/disableexperiencemetrics"
                "/logpath `"$LogDirectory`""
            )

            Write-Output "Arguments : $($Arguments -join ' ')"
            Write-Output "Starting Citrix Delivery Controller installer asynchronously..."

            $WrapperScript = @"
`$ErrorActionPreference = 'Stop'
`$Installer = '$Installer'
`$Arguments = @(
    '/components controller,desktopstudio,webstudio,desktopdirector'
    '/nosql'
    '/quiet'
    '/noreboot'
    '/no_pending_reboot_check'
    '/disableexperiencemetrics'
    '/logpath `"$LogDirectory`"'
)
try {
    & `$Installer @Arguments
    `$ExitCode = `$LASTEXITCODE
}
catch {
    `$ExitCode = 1
}
Set-Content -LiteralPath '$ResultFile' -Value `$ExitCode -Force
exit `$ExitCode
"@

            $EncodedCommand = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($WrapperScript)
            )

            $Wrapper = Start-Process `
                -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList @(
                    '-NoProfile'
                    '-NonInteractive'
                    '-ExecutionPolicy Bypass'
                    '-EncodedCommand'
                    $EncodedCommand
                ) `
                -WindowStyle Hidden `
                -PassThru `
                -ErrorAction Stop

            Write-Output "Installer wrapper started."
            Write-Output "Wrapper Process ID : $($Wrapper.Id)"

            [pscustomobject]@{
                WrapperProcessId = $Wrapper.Id
                ResultFile = $ResultFile
                LogFile = "$LogDirectory\CitrixDDCInstall.log"
            }

        } -ArgumentList $RemoteInstaller, $LogDirectory, $ResultFile -ErrorAction Stop

        $WrapperPid = [int]$InstallState.WrapperProcessId
        $InstallResultFile = $InstallState.ResultFile
        $InstallLogFile = $InstallState.LogFile

        Write-Output "Citrix installer launched successfully."
        Write-Output "Wrapper Process ID : $WrapperPid"
        Write-Output "Installation is running independently of the WinRM command session."

        $InstallCompleted = $false
        $InstallElapsedSeconds = 0
        $InstallHeartbeatSeconds = 30
        $InstallTimeoutSeconds = 7200
        $ExitCode = $null

        while (-not $InstallCompleted) {

            Start-Sleep -Seconds $InstallHeartbeatSeconds
            $InstallElapsedSeconds += $InstallHeartbeatSeconds

            $RemoteStatus = $null

            try {
                $RemoteStatus = Invoke-Command -Session $Session -ScriptBlock {
                    param($ProcessId, $ResultFile)

                    $Result = [ordered]@{
                        Running = $false
                        Completed = $false
                        ExitCode = $null
                    }

                    if (Test-Path -LiteralPath $ResultFile) {
                        $RawExitCode = (Get-Content -LiteralPath $ResultFile -Raw -ErrorAction SilentlyContinue).Trim()

                        if ($RawExitCode -match '^-?\d+$') {
                            $Result.ExitCode = [int]$RawExitCode
                            $Result.Completed = $true
                        }
                    }

                    $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue

                    if ($Process) {
                        $Result.Running = $true
                    }

                    [pscustomobject]$Result

                } -ArgumentList $WrapperPid, $InstallResultFile -ErrorAction Stop
            }
            catch {
                Write-Output "Unable to query installer state. Retrying..."
                Write-Output "Reason: $($_.Exception.Message)"
            }

            if ($RemoteStatus -and $RemoteStatus.Completed) {
                $InstallCompleted = $true
                $ExitCode = [int]$RemoteStatus.ExitCode
                Write-Output "Citrix installer completed."
                Write-Output "Installation elapsed time: $InstallElapsedSeconds seconds."
                Write-Output "Citrix installer exit code: $ExitCode"
                break
            }

            if ($RemoteStatus -and $RemoteStatus.Running) {
                Write-Output "Citrix installer still running... $InstallElapsedSeconds seconds elapsed."
            }
            else {
                Write-Output "Citrix installer state not yet finalized... $InstallElapsedSeconds seconds elapsed."
            }

            if ($InstallElapsedSeconds -ge $InstallTimeoutSeconds) {
                throw "Citrix Delivery Controller installer exceeded the $InstallTimeoutSeconds second timeout. Check $InstallLogFile on the target server."
            }
        }

        if ($null -eq $ExitCode) {
            throw "Citrix installer exit code was not returned. Check $InstallLogFile on the target server."
        }

        if ($ExitCode -notin @(0, 3010, 1641)) {
            throw "Citrix Delivery Controller installation failed with exit code $ExitCode. Check $InstallLogFile on the target server."
        }

        if ($ExitCode -eq 3010) {
            $RebootCount++

            if ($RebootCount -gt $MaxReboots) {
                throw "Citrix installer requires a reboot, but the maximum automatic reboot limit of $MaxReboots has been reached."
            }

            Write-Output "Installer completed successfully and requires a reboot."
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
        }
        elseif ($ExitCode -eq 1641) {
            $RebootCount++

            if ($RebootCount -gt $MaxReboots) {
                throw "Citrix installer initiated a reboot, but the maximum automatic reboot limit of $MaxReboots has been reached."
            }

            Write-Output "Installer initiated a reboot."
            Write-Output "Automatic reboot: $RebootCount of $MaxReboots"
            Write-Output "Waiting for the server to return."
            Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
            $Session = $null
        }
        else {
            Write-Output "Installer completed without requesting a reboot."
        }
    }

    # --------------------------------------------------------
    # Reconnect after reboot if required
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
    # Validate DDC services
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Validating Citrix Delivery Controller services"
    Write-Output "============================================================"

    $ServiceNames = @(
        "CitrixBrokerService",
        "CitrixConfigurationLogging",
        "CitrixHostService",
        "CitrixMachineCreationService",
        "CitrixMonitor"
    )

    $Services = $null
    $ServiceValidationComplete = $false
    $ServiceWaitSeconds = 300
    $ServicePollSeconds = 15
    $ServiceElapsedSeconds = 0

    while (-not $ServiceValidationComplete -and $ServiceElapsedSeconds -lt $ServiceWaitSeconds) {

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
            $ServiceValidationComplete = $true
            break
        }

        Write-Output "Waiting for Citrix services to initialize..."
        Write-Output "Missing services: $($MissingServices -join ', ')"
        Write-Output "Elapsed: $ServiceElapsedSeconds seconds of $ServiceWaitSeconds"

        Start-Sleep -Seconds $ServicePollSeconds
        $ServiceElapsedSeconds += $ServicePollSeconds
    }

    if (-not $Services) {
        throw "No expected Citrix Delivery Controller services were found after installation. Check $LogFile"
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

    # --------------------------------------------------------
    # Final service validation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Final Citrix Delivery Controller service status"
    Write-Output "============================================================"

    $FinalServices = Invoke-Command -Session $Session -ScriptBlock {
        param($Names)

        foreach ($Name in $Names) {
            Get-Service -Name $Name -ErrorAction SilentlyContinue
        }
    } -ArgumentList (,$ServiceNames) -ErrorAction Stop

    $FinalServices |
        Select-Object Name, Status, StartType |
        Sort-Object Name |
        Format-Table -AutoSize |
        Out-String |
        Write-Output

    $StoppedServices = $FinalServices | Where-Object { $_.Status -ne "Running" }

    if ($StoppedServices) {
        throw "One or more required Citrix Delivery Controller services are not running: $($StoppedServices.Name -join ', ')"
    }

    # --------------------------------------------------------
    # Validate Citrix installation directories
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "Checking Citrix installation directories..."

    Invoke-Command -Session $Session -ScriptBlock {

        $CitrixPaths = @(
            "C:\Program Files\Citrix\Broker",
            "C:\Program Files\Citrix\Studio",
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

    } -ErrorAction Stop

    # --------------------------------------------------------
    # Cleanup package after successful validation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Cleaning up installation package"
    Write-Output "============================================================"

    Invoke-Command -Session $Session -ScriptBlock {

        $Path = "C:\Source\CVAD"

        if (Test-Path -LiteralPath $Path) {
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
    Write-Output "CITRIX DELIVERY CONTROLLER INSTALLATION COMPLETED"
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
