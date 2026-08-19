# Install-CitrixDDC_v1.ps1
# Versioned DDC installer with controlled reboot handling.
# NOTE: This version is intentionally based on the existing full DDC runbook structure.

$ErrorActionPreference = "Stop"

Write-Output "============================================================"
Write-Output "Citrix Delivery Controller Installation v1"
Write-Output "============================================================"

$ComputerName = Get-AutomationVariable -Name "DDCComputerName"
$Source = Get-AutomationVariable -Name "CitrixMediaPath"
$KeyVaultName = Get-AutomationVariable -Name "KeyVaultName"
$CredentialSecretName = Get-AutomationVariable -Name "CitrixCredentialSecretName"

if ([string]::IsNullOrWhiteSpace($ComputerName)) { throw "Automation variable 'DDCComputerName' is missing." }
if ([string]::IsNullOrWhiteSpace($Source)) { throw "Automation variable 'CitrixMediaPath' is missing." }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { throw "Automation variable 'KeyVaultName' is missing." }
if ([string]::IsNullOrWhiteSpace($CredentialSecretName)) { throw "Automation variable 'CitrixCredentialSecretName' is missing." }

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
Import-Module Az.KeyVault -Force -ErrorAction Stop

Write-Output "Az.Accounts : $((Get-Module Az.Accounts).Version)"
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
# Key Vault REST API
# ------------------------------------------------------------

Write-Output ""
Write-Output "============================================================"
Write-Output "Retrieving credential from Key Vault"
Write-Output "============================================================"

$TokenResponse = Invoke-RestMethod `
    -Method GET `
    -Headers @{ Metadata = "true" } `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" `
    -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($TokenResponse.access_token)) {
    throw "Managed Identity token for Key Vault was not returned."
}

$Headers = @{ Authorization = "Bearer $($TokenResponse.access_token)" }
$VaultUri = "https://$KeyVaultName.vault.azure.net"
$SecretUri = "$VaultUri/secrets/$CredentialSecretName?api-version=7.4"

$SecretResponse = Invoke-RestMethod `
    -Method GET `
    -Uri $SecretUri `
    -Headers $Headers `
    -ErrorAction Stop

if ($null -eq $SecretResponse -or [string]::IsNullOrWhiteSpace($SecretResponse.value)) {
    throw "Key Vault returned an empty secret."
}

try { $CredentialData = $SecretResponse.value | ConvertFrom-Json }
catch { throw "Key Vault secret '$CredentialSecretName' is not valid JSON." }

if ([string]::IsNullOrWhiteSpace($CredentialData.Username)) { throw "Username is missing from Key Vault secret '$CredentialSecretName'." }
if ([string]::IsNullOrWhiteSpace($CredentialData.Password)) { throw "Password is missing from Key Vault secret '$CredentialSecretName'." }

$SecurePassword = ConvertTo-SecureString $CredentialData.Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($CredentialData.Username,$SecurePassword)

Write-Output "Credential loaded successfully."
Write-Output "Username : $($CredentialData.Username)"

# ------------------------------------------------------------
# Reboot / WinRM helpers
# ------------------------------------------------------------

$MaxReboots = 2
$RebootCount = 0

function Wait-ForWinRM {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds = 900
    )

    Write-Output "Waiting for $ComputerName to become available through WinRM..."
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            Test-WSMan -ComputerName $ComputerName -Authentication Negotiate -Credential $Credential -ErrorAction Stop | Out-Null
            Write-Output "WinRM connectivity restored."
            return $true
        }
        catch {
            Start-Sleep -Seconds 15
        }
    }

    throw "Timed out waiting for WinRM on $ComputerName after $TimeoutSeconds seconds."
}

function Restart-TargetAndReconnect {
    param(
        [System.Management.Automation.PSSession]$Session,
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$Reason
    )

    $script:RebootCount++

    if ($script:RebootCount -gt $MaxReboots) {
        throw "Maximum allowed reboots ($MaxReboots) exceeded. Last reboot reason: $Reason"
    }

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "REBOOT REQUIRED"
    Write-Output "============================================================"
    Write-Output "Reason : $Reason"
    Write-Output "Reboot : $script:RebootCount of $MaxReboots"

    if ($null -ne $Session) {
        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
    }

    Restart-Computer -ComputerName $ComputerName -Credential $Credential -Force -ErrorAction Stop

    Wait-ForWinRM -ComputerName $ComputerName -Credential $Credential

    Write-Output "Creating new remote PowerShell session..."
    return New-PSSession -ComputerName $ComputerName -Authentication Negotiate -Credential $Credential -ErrorAction Stop
}

# ------------------------------------------------------------
# Initial WinRM
# ------------------------------------------------------------

Write-Output ""
Write-Output "Testing WinRM..."
Test-WSMan -ComputerName $ComputerName -Authentication Negotiate -Credential $Credential -ErrorAction Stop | Out-Null
Write-Output "WinRM connectivity: SUCCESS"

$Session = New-PSSession -ComputerName $ComputerName -Authentication Negotiate -Credential $Credential -ErrorAction Stop
Write-Output "Remote session: SUCCESS"

try {
    $RemoteRoot = "C:\Source\CVAD"
    $RemoteInstaller = "C:\Source\CVAD\x64\XenDesktop Setup\XenDesktopServerSetup.exe"
    $LogDirectory = "C:\Temp"
    $LogFile = "C:\Temp\CitrixDDCInstall.log"

    # --------------------------------------------------------
    # Target pre-flight checks with automatic pending reboot
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC PRE-FLIGHT VALIDATION"
    Write-Output "============================================================"

    $Preflight = Invoke-Command -Session $Session -ScriptBlock {
        $OS = Get-CimInstance Win32_OperatingSystem
        $Computer = Get-CimInstance Win32_ComputerSystem
        $ReleaseKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction SilentlyContinue
        $PendingReboot = $false
        $PendingPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        )
        foreach ($Path in $PendingPaths) { if (Test-Path $Path) { $PendingReboot = $true } }
        $CBSReboot = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($CBSReboot) { $PendingReboot = $true }
        $Volume = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME
            OS = $OS.Caption
            OSBuild = $OS.BuildNumber
            DomainJoined = [bool]$Computer.PartOfDomain
            Domain = $Computer.Domain
            IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
            DotNetRelease = if ($ReleaseKey) { $ReleaseKey.Release } else { $null }
            DotNet48OrLater = if ($ReleaseKey) { $ReleaseKey.Release -ge 528040 } else { $false }
            PendingReboot = $PendingReboot
            FreeSpaceGB = if ($Volume) { [math]::Round($Volume.FreeSpace / 1GB,2) } else { $null }
            RAMGB = [math]::Round($Computer.TotalPhysicalMemory / 1GB,2)
        }
    } -ErrorAction Stop

    $Preflight | Format-List | Out-String | Write-Output

    if (-not $Preflight.DomainJoined) { throw "DDC target is not domain joined." }
    if ($Preflight.IsDomainController) { throw "DDC installation target is a Domain Controller. Citrix Delivery Controller must not be installed on a Domain Controller." }
    if ($null -eq $Preflight.FreeSpaceGB -or $Preflight.FreeSpaceGB -lt 10) { throw "Insufficient free space on C:. At least 10 GB is required for this automated installation staging area." }
    if ($Preflight.RAMGB -lt 5) { throw "Insufficient RAM for Citrix Delivery Controller. Detected $($Preflight.RAMGB) GB; Citrix requires at least 5 GB." }

    if ($Preflight.PendingReboot) {
        $Session = Restart-TargetAndReconnect -Session $Session -ComputerName $ComputerName -Credential $Credential -Reason "A Windows pending reboot was detected during DDC pre-flight."

        $Preflight = Invoke-Command -Session $Session -ScriptBlock {
            $OS = Get-CimInstance Win32_OperatingSystem
            $Computer = Get-CimInstance Win32_ComputerSystem
            $Pending = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
                       (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
            $Rename = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
            if ($Rename) { $Pending = $true }
            [pscustomobject]@{
                DomainJoined = [bool]$Computer.PartOfDomain
                IsDomainController = [bool](Get-Service -Name NTDS -ErrorAction SilentlyContinue)
                PendingReboot = $Pending
                RAMGB = [math]::Round($Computer.TotalPhysicalMemory / 1GB,2)
            }
        } -ErrorAction Stop

        if ($Preflight.PendingReboot) { throw "Target still reports a pending reboot after the automated reboot." }
        Write-Output "Post-reboot pre-flight validation: SUCCESS"
    }

    Write-Output "DDC pre-flight validation: SUCCESS"

    # --------------------------------------------------------
    # Package reuse / copy
    # --------------------------------------------------------

    $PackageExists = Invoke-Command -Session $Session -ScriptBlock {
        param($InstallerPath)
        Test-Path -LiteralPath $InstallerPath
    } -ArgumentList $RemoteInstaller -ErrorAction Stop

    if ($PackageExists) {
        Write-Output "Existing package found. Skipping package copy."
    }
    else {
        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null
        } -ArgumentList $RemoteRoot -ErrorAction Stop

        Write-Output "Copying Citrix DDC package..."
        Copy-Item -Path "$Source\*" -Destination $RemoteRoot -ToSession $Session -Recurse -Force -ErrorAction Stop -Verbose
        Write-Output "Package copy: SUCCESS"
    }

    # --------------------------------------------------------
    # Verify installer
    # --------------------------------------------------------

    if (-not (Invoke-Command -Session $Session -ScriptBlock { param($Path) Test-Path -LiteralPath $Path } -ArgumentList $RemoteInstaller -ErrorAction Stop)) {
        throw "Citrix Delivery Controller installer was not found at $RemoteInstaller"
    }

    Write-Output "Installer verification: SUCCESS"

    # --------------------------------------------------------
    # Install DDC - controlled reboot
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "INSTALLING CITRIX DELIVERY CONTROLLER"
    Write-Output "============================================================"

    $InstallResult = Invoke-Command -Session $Session -ScriptBlock {
        param($Installer,$LogDirectory)
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        $Arguments = @(
            "/components controller,desktopstudio,webstudio,desktopdirector"
            "/nosql"
            "/quiet"
            "/noreboot"
            "/no_pending_reboot_check"
            "/disableexperiencemetrics"
            "/logpath `"$LogDirectory`""
        ) -join " "
        Write-Output "Installer : $Installer"
        Write-Output "Arguments : $Arguments"
        $Process = Start-Process -FilePath $Installer -ArgumentList $Arguments -Wait -PassThru
        [pscustomobject]@{ ExitCode = $Process.ExitCode }
    } -ArgumentList $RemoteInstaller,$LogDirectory -ErrorAction Stop

    $ExitCode = [int]$InstallResult.ExitCode
    Write-Output "Citrix installer exit code : $ExitCode"

    if ($ExitCode -notin @(0,3010,1641)) {
        throw "Citrix Delivery Controller installation failed with exit code $ExitCode. Check $LogFile on the target server."
    }

    if ($ExitCode -in @(3010,1641)) {
        $Session = Restart-TargetAndReconnect -Session $Session -ComputerName $ComputerName -Credential $Credential -Reason "Citrix Delivery Controller installer returned reboot-required exit code $ExitCode."
    }

    # --------------------------------------------------------
    # Post-install service validation
    # --------------------------------------------------------

    Write-Output ""
    Write-Output "============================================================"
    Write-Output "DDC POST-INSTALL VALIDATION"
    Write-Output "============================================================"

    $ExpectedServices = @(
        "CitrixBrokerService",
        "CitrixMonitorService",
        "CitrixConfigurationService",
        "CitrixConfigLoggingService",
        "CitrixHighAvailabilityService",
        "CitrixHostService",
        "CitrixMachineCreationService"
    )

    $Deadline = (Get-Date).AddMinutes(5)
    $Services = $null

    while ((Get-Date) -lt $Deadline) {
        $Services = Invoke-Command -Session $Session -ScriptBlock {
            param($Names)
            Get-Service -Name $Names -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType
        } -ArgumentList (,$ExpectedServices) -ErrorAction Stop

        $Missing = $ExpectedServices | Where-Object { $_ -notin @($Services.Name) }
        if (-not $Missing) { break }

        Write-Output "Waiting for Citrix services to initialize: $($Missing -join ', ')"
        Start-Sleep -Seconds 15
    }

    $Missing = $ExpectedServices | Where-Object { $_ -notin @($Services.Name) }
    if ($Missing) { throw "Expected Citrix Delivery Controller services are missing after the validation wait: $($Missing -join ', ')" }

    foreach ($Service in $Services) {
        if ($Service.Status -ne "Running") {
            Write-Output "Starting service: $($Service.Name)"
            Invoke-Command -Session $Session -ScriptBlock { param($Name) Start-Service -Name $Name -ErrorAction Stop } -ArgumentList $Service.Name -ErrorAction Stop
        }
    }

    $FinalServices = Invoke-Command -Session $Session -ScriptBlock {
        param($Names)
        Get-Service -Name $Names -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType
    } -ArgumentList (,$ExpectedServices) -ErrorAction Stop

    $NotRunning = $FinalServices | Where-Object { $_.Status -ne "Running" }
    if ($NotRunning) { throw "Citrix DDC services are not running: $(($NotRunning.Name) -join ', ')" }

    $FinalServices | Format-Table -AutoSize | Out-String | Write-Output
    Write-Output "DDC installation validation: SUCCESS"

    # --------------------------------------------------------
    # Cleanup
    # --------------------------------------------------------

    Write-Output "Removing staged Citrix package..."
    Invoke-Command -Session $Session -ScriptBlock {
        if (Test-Path "C:\Source\CVAD") { Remove-Item "C:\Source\CVAD" -Recurse -Force -ErrorAction Stop }
    } -ErrorAction Stop

    Write-Output "Cleanup: SUCCESS"
}
finally {
    if ($null -ne $Session) {
        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
    }
}

Write-Output ""
Write-Output "============================================================"
Write-Output "CITRIX DELIVERY CONTROLLER INSTALLATION v1 COMPLETED"
Write-Output "============================================================"