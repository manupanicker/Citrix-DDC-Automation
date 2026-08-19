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
        # Install DDC through a detached Scheduled Task
        # ----------------------------------------------------

        Write-Output ""
        Write-Output "============================================================"
        Write-Output "Installing Citrix Delivery Controller"
        Write-Output "============================================================"

        $InstallState = Invoke-Command -Session $Session -ScriptBlock {
            param($Installer, $LogDirectory, $ResultFile, $RunAsUser, $RunAsPassword)

            $ErrorActionPreference = "Stop"

            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

            $StartedFile = Join-Path $LogDirectory "CitrixDDCInstall.started"
            $PidFile = Join-Path $LogDirectory "CitrixDDCInstall.pid"
            $ErrorFile = Join-Path $LogDirectory "CitrixDDCInstall.error"
            $LauncherScript = Join-Path $LogDirectory "CitrixDDCInstallLauncher.ps1"
            $TaskName = "CitrixDDCInstall-$([guid]::NewGuid().ToString('N'))"

            Remove-Item -LiteralPath $ResultFile,$StartedFile,$PidFile,$ErrorFile -Force -ErrorAction SilentlyContinue

            Write-Output "Installer : $Installer"
            Write-Output "Log       : $LogDirectory"
            Write-Output "Result    : $ResultFile"
            Write-Output "Run As    : $RunAsUser"
            Write-Output "Task      : $TaskName"

            $LauncherContent = @"
param(
    [Parameter(Mandatory=`$true)][string]`$Installer,
    [Parameter(Mandatory=`$true)][string]`$LogDirectory,
    [Parameter(Mandatory=`$true)][string]`$ResultFile,
    [Parameter(Mandatory=`$true)][string]`$StartedFile,
    [Parameter(Mandatory=`$true)][string]`$PidFile,
    [Parameter(Mandatory=`$true)][string]`$ErrorFile
)

`$ErrorActionPreference = "Stop"

try {
    New-Item -Path `$LogDirectory -ItemType Directory -Force | Out-Null

    Set-Content -LiteralPath `$StartedFile -Value "Launcher started: `$(Get-Date -Format o)" -Force
    Remove-Item -LiteralPath `$ResultFile,`$PidFile,`$ErrorFile -Force -ErrorAction SilentlyContinue

    `$Arguments = @(
        "/components controller,desktopstudio,webstudio,desktopdirector"
        "/nosql"
        "/quiet"
        "/noreboot"
        "/no_pending_reboot_check"
        "/disableexperiencemetrics"
        "/logpath `"`$LogDirectory`""
    )

    `$Process = Start-Process `
        -FilePath `$Installer `
        -ArgumentList `$Arguments `
        -PassThru `
        -ErrorAction Stop

    Set-Content -LiteralPath `$PidFile -Value `$Process.Id -Force

    `$Process.WaitForExit()
    `$ExitCode = `$Process.ExitCode

    Set-Content -LiteralPath `$ResultFile -Value `$ExitCode -Force
}
catch {
    Set-Content -LiteralPath `$ErrorFile -Value (`$_.Exception | Out-String) -Force
    Set-Content -LiteralPath `$ResultFile -Value 1 -Force
}
"@

            Set-Content -LiteralPath $LauncherScript -Value $LauncherContent -Encoding UTF8 -Force

            $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $TaskArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$LauncherScript`" -Installer `"$Installer`" -LogDirectory `"$LogDirectory`" -ResultFile `"$ResultFile`" -StartedFile `"$StartedFile`" -PidFile `"$PidFile`" -ErrorFile `"$ErrorFile`""

            $Action = New-ScheduledTaskAction `
                -Execute $PowerShell `
                -Argument $TaskArguments

            $Trigger = New-ScheduledTaskTrigger `
                -Once `
                -At (Get-Date)

            $Principal = New-ScheduledTaskPrincipal `
                -UserId $RunAsUser `
                -LogonType Password `
                -RunLevel Highest

            $Settings = New-ScheduledTaskSettingsSet `
                -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
                -StartWhenAvailable `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries

            Write-Output "Registering detached Scheduled Task..."

            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $Action `
                -Trigger $Trigger `
                -Principal $Principal `
                -Settings $Settings `
                -User $RunAsUser `
                -Password $RunAsPassword `
                -Force | Out-Null

            Write-Output "Scheduled Task registered successfully."
            Write-Output "Starting Scheduled Task..."

            Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop

            Start-Sleep -Seconds 3

            $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            $TaskInfo = if ($Task) { Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue } else { $null }

            if (-not (Test-Path -LiteralPath $StartedFile)) {
                Write-Output "WARNING: Launcher started marker is not yet present. Scheduled Task was started, but the target-side launcher has not reported in yet."
            }
            else {
                Write-Output "Launcher started marker confirmed."
            }

            [pscustomobject]@{
                TaskName = $TaskName
                TaskState = if ($Task) { $Task.State.ToString() } else { "Unknown" }
                LastTaskRunTime = if ($TaskInfo) { $TaskInfo.LastRunTime } else { $null }
                StartedFile = $StartedFile
                PidFile = $PidFile
                ResultFile = $ResultFile
                ErrorFile = $ErrorFile
                LogFile = "$LogDirectory\CitrixDDCInstall.log"
            }

        } -ArgumentList $RemoteInstaller, $LogDirectory, $ResultFile, $Credential.UserName, $Credential.GetNetworkCredential().Password -ErrorAction Stop

        $InstallTaskName = $InstallState.TaskName
        $InstallStartedFile = $InstallState.StartedFile
        $InstallPidFile = $InstallState.PidFile
        $InstallResultFile = $InstallState.ResultFile
        $InstallErrorFile = $InstallState.ErrorFile
        $InstallLogFile = $InstallState.LogFile

        Write-Output "Citrix installer Scheduled Task created successfully."
        Write-Output "Task Name : $InstallTaskName"
        Write-Output "Run As    : $($Credential.UserName)"
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
                    param($TaskName, $StartedFile, $PidFile, $ResultFile, $ErrorFile)

                    $Result = [ordered]@{
                        Running = $false
                        Completed = $false
                        Failed = $false
                        ExitCode = $null
                        CitrixProcessRunning = $false
                        TaskState = "Unknown"
                        Error = $null
                    }

                    if (Test-Path -LiteralPath $ResultFile) {
                        $RawExitCode = Get-Content -LiteralPath $ResultFile -Raw -ErrorAction SilentlyContinue

                        if ($null -ne $RawExitCode) {
                            $RawExitCode = $RawExitCode.Trim()

                            if (-not [string]::IsNullOrWhiteSpace($RawExitCode) -and $RawExitCode -match '^-?\d+$') {
                                $Result.ExitCode = [int]$RawExitCode
                                $Result.Completed = $true
                            }
                        }
                    }

                    if (Test-Path -LiteralPath $ErrorFile) {
                        $Result.Error = Get-Content -LiteralPath $ErrorFile -Raw -ErrorAction SilentlyContinue
                    }

                    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                    if ($Task) {
                        $Result.TaskState = $Task.State.ToString()
                    }

                    if (-not $Result.Completed) {
                        $CurrentCitrixPid = $null

                        if (Test-Path -LiteralPath $PidFile) {
                            $RawPid = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
                            if ($null -ne $RawPid -and $RawPid.Trim() -match '^\d+$') {
                                $CurrentCitrixPid = [int]$RawPid.Trim()
                            }
                        }

                        if ($null -ne $CurrentCitrixPid) {
                            $Process = Get-Process -Id $CurrentCitrixPid -ErrorAction SilentlyContinue
                            if ($null -ne $Process) {
                                $Result.Running = $true
                                $Result.CitrixProcessRunning = $true
                            }
                        }

                        if (-not $Result.Running -and (Test-Path -LiteralPath $StartedFile)) {
                            if ($Task -and $Task.State -in @("Running","Queued")) {
                                $Result.Running = $true
                            }
                            elseif ($Result.Error) {
                                $Result.Failed = $true
                            }
                            else {
                                $Result.Running = $true
                            }
                        }
                    }

                    [pscustomobject]$Result

                } -ArgumentList $InstallTaskName, $InstallStartedFile, $InstallPidFile, $InstallResultFile, $InstallErrorFile -ErrorAction Stop
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

            if ($RemoteStatus -and $RemoteStatus.Failed) {
                $FailureDetail = if ($RemoteStatus.Error) { $RemoteStatus.Error } else { "No launcher error was recorded." }
                throw "Citrix installer launcher failed before producing a valid exit code. $FailureDetail Check $InstallLogFile on the target server."
            }

            if ($RemoteStatus -and $RemoteStatus.CitrixProcessRunning) {
                Write-Output "Citrix installer still running... $InstallElapsedSeconds seconds elapsed."
            }
            elseif ($RemoteStatus -and $RemoteStatus.Running) {
                Write-Output "Citrix installer task is running; waiting for installer state... $InstallElapsedSeconds seconds elapsed."
            }
            else {
                Write-Output "Citrix installer state not yet finalized... $InstallElapsedSeconds seconds elapsed."
            }

            if ($InstallElapsedSeconds -ge $InstallTimeoutSeconds) {
                throw "Citrix Delivery Controller installer exceeded the $InstallTimeoutSeconds second timeout. Check $InstallLogFile on the target server."
            }
        }

        try {
            Invoke-Command -Session $Session -ScriptBlock {
                param($TaskName)
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            } -ArgumentList $InstallTaskName -ErrorAction SilentlyContinue | Out-Null
            Write-Output "Temporary Citrix installer Scheduled Task removed."
        }
        catch {
            Write-Output "WARNING: Unable to remove temporary Scheduled Task '$InstallTaskName'. It can be removed manually after installation."
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
            throw "Target server did not become available through WinRM after the Citrix installer reboot."
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

    $ExpectedServices = @(
        "CitrixBrokerService",
        "CitrixMonitor",
        "CitrixHostService",
        "CitrixMachineCreationService",
        "CitrixConfigService"
    )

    $ServiceResult = Invoke-Command -Session $Session -ScriptBlock {
        param($ServiceNames)

        $Results = foreach ($Name in $ServiceNames) {
            $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue

            if ($null -eq $Service) {
                [pscustomobject]@{
                    Name = $Name
                    Status = "MISSING"
                    DisplayName = ""
                }
            }
            else {
                [pscustomobject]@{
                    Name = $Service.Name
                    Status = $Service.Status.ToString()
                    DisplayName = $Service.DisplayName
                }
            }
        }

        $Results

    } -ArgumentList (,$ExpectedServices) -ErrorAction Stop

    $ServiceResult | Format-Table -AutoSize | Out-String | Write-Output

    $MissingServices = @($ServiceResult | Where-Object { $_.Status -eq "MISSING" })

    if ($MissingServices.Count -gt 0) {
        $MissingNames = ($MissingServices.Name -join ", ")
        throw "Expected Citrix Delivery Controller services are missing: $MissingNames"
    }

    $StoppedServices = @($ServiceResult | Where-Object { $_.Status -ne "Running" })

    if ($StoppedServices.Count -gt 0) {
        Write-Output "Some expected Citrix services are not currently running. Attempting to start them..."

        Invoke-Command -Session $Session -ScriptBlock {
            param($ServiceNames)

            foreach ($Name in $ServiceNames) {
                $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue

                if ($Service -and $Service.Status -ne "Running") {
                    Start-Service -Name $Name -ErrorAction SilentlyContinue
                }
            }

        } -ArgumentList (,$ExpectedServices) -ErrorAction SilentlyContinue | Out-Null

        Start-Sleep -Seconds 15

        $ServiceResult = Invoke-Command -Session $Session -ScriptBlock {
            param($ServiceNames)

            foreach ($Name in $ServiceNames) {
                $Service = Get-Service -Name $Name -ErrorAction SilentlyContinue

                if ($null -eq $Service) {
                    [pscustomobject]@{
                        Name = $Name
                        Status = "MISSING"
                    }
                }
                else {
                    [pscustomobject]@{
                        Name = $Service.Name
                        Status = $Service.Status.ToString()
                    }
                }
            }

        } -ArgumentList (,$ExpectedServices) -ErrorAction Stop
    }

    $MissingServices = @($ServiceResult | Where-Object { $_.Status -eq "MISSING" })

    if ($MissingServices.Count -gt 0) {
        $MissingNames = ($MissingServices.Name -join ", ")
        throw "Expected Citrix Delivery Controller services are missing: $MissingNames"
    }

    Write-Output "Citrix Delivery Controller service validation: SUCCESS"

    # --------------------------------------------------------
    # Final validation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC INSTALLATION VALIDATION"
    Write-Output "============================================================"

    $FinalValidation = Invoke-Command -Session $Session -ScriptBlock {

        $Broker = Get-Service -Name "CitrixBrokerService" -ErrorAction SilentlyContinue
        $Monitor = Get-Service -Name "CitrixMonitor" -ErrorAction SilentlyContinue
        $HostService = Get-Service -Name "CitrixHostService" -ErrorAction SilentlyContinue

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            BrokerService = if ($Broker) { $Broker.Status.ToString() } else { "MISSING" }
            MonitorService = if ($Monitor) { $Monitor.Status.ToString() } else { "MISSING" }
            HostService = if ($HostService) { $HostService.Status.ToString() } else { "MISSING" }
        }

    } -ErrorAction Stop

    $FinalValidation | Format-List | Out-String | Write-Output

    if ($FinalValidation.BrokerService -eq "MISSING" -or
        $FinalValidation.MonitorService -eq "MISSING" -or
        $FinalValidation.HostService -eq "MISSING") {
        throw "Citrix Delivery Controller final validation failed because one or more core services are missing."
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "Citrix Delivery Controller installation completed successfully."
    Write-Output "============================================================"

}
finally {

    if ($null -ne $Session) {
        Write-Output "Closing remote PowerShell session..."
        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
        Write-Output "Remote session closed."
    }
}
