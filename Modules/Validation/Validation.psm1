function Test-PowerShellVersion {

    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return $true
    }

    return $false
}

function Test-Administrator {

    [CmdletBinding()]
    param()

    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-WinRM {

    [CmdletBinding()]
    param()

    try {
        $Service = Get-Service WinRM -ErrorAction Stop

        return ($Service.Status -eq "Running")
    }
    catch {
        return $false
    }
}
function Test-DiskSpace {

    [CmdletBinding()]
    param(
        [int]$MinimumGB = 20
    )

    $Drive = Get-CimInstance Win32_LogicalDisk |
             Where-Object DeviceID -eq "C:"

    $FreeGB = [math]::Round($Drive.FreeSpace / 1GB,2)

    return @{
        Passed = ($FreeGB -ge $MinimumGB)
        FreeGB = $FreeGB
    }
}

function Test-OperatingSystem {

    [CmdletBinding()]
    param()

    $OS = Get-CimInstance Win32_OperatingSystem

    return @{
        Passed = ($OS.Caption -like "*Windows Server*")
        Name   = $OS.Caption
        Version = $OS.Version
    }
}

function Test-PendingReboot {

    [CmdletBinding()]
    param()

    $Pending = $false

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $Pending = $true
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $Pending = $true
    }

    return @{
        Passed = (-not $Pending)
        PendingReboot = $Pending
    }
}

Export-ModuleMember -Function Test-PowerShellVersion, Test-Administrator, Test-WinRM, Test-DiskSpace, Test-OperatingSystem, Test-PendingReboot
