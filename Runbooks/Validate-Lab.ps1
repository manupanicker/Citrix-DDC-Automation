Import-Module "$PSScriptRoot\..\Modules\Common\Logging.psm1" -Force
Import-Module "$PSScriptRoot\..\Modules\Common\Configuration.psm1" -Force
Import-Module "$PSScriptRoot\..\Modules\Validation\Validation.psm1" -Force
Import-Module "$PSScriptRoot\..\Modules\Windows\Windows.psm1" -Force

$config = Get-Configuration

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " AlphaQ Infrastructure Validation"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Starting validation"

#----------------------------------------------------------
# PowerShell Version
#----------------------------------------------------------

if (Test-PowerShellVersion) {
    Write-Log "PowerShell Version OK" -Level SUCCESS
}
else {
    Write-Log "PowerShell 7 or later is required." -Level ERROR
}

#----------------------------------------------------------
# Administrator
#----------------------------------------------------------

if (Test-Administrator) {
    Write-Log "Running as Administrator" -Level SUCCESS
}
else {
    Write-Log "Not running as Administrator" -Level ERROR
}

#----------------------------------------------------------
# WinRM
#----------------------------------------------------------

Write-ValidationResult `
    -Check "WinRM" `
    -Passed (Test-WinRM) `
    -SuccessMessage "Service Running" `
    -FailureMessage "Service Not Running"

#----------------------------------------------------------
# Disk Space
#----------------------------------------------------------

$Disk = Test-DiskSpace

if ($Disk.Passed) {
    Write-Log "C: Drive Free Space: $($Disk.FreeGB) GB" -Level SUCCESS
}
else {
    Write-Log "Only $($Disk.FreeGB) GB free on C: drive" -Level ERROR
}

#----------------------------------------------------------
# Operating System
#----------------------------------------------------------

$OS = Test-OperatingSystem

if ($OS.Passed) {

    Write-Log "Operating System: $($OS.Name) ($($OS.Version))" -Level SUCCESS

    #------------------------------------------------------
    # Windows Features
    #------------------------------------------------------

    $WindowsFeatures = Test-WindowsFeatures

    foreach ($Feature in $WindowsFeatures) {

        if ($Feature.Installed) {
            Write-Log "$($Feature.Name) is installed" -Level SUCCESS
        }
        else {
            Write-Log "$($Feature.Name) is NOT installed" -Level ERROR
        }
    }
}
else {

    Write-Log "Unsupported Operating System: $($OS.Name)" -Level ERROR
    Write-Log "Skipping Windows feature validation." -Level INFO
}

#----------------------------------------------------------
# Pending Reboot
#----------------------------------------------------------

$Reboot = Test-PendingReboot

if ($Reboot.Passed) {
    Write-Log "No pending reboot detected" -Level SUCCESS
}
else {
    Write-Log "Pending reboot detected" -Level ERROR
}

#----------------------------------------------------------
# Configuration
#----------------------------------------------------------

Write-Log "Configuration loaded for $($config.Company)" -Level SUCCESS

Write-Host ""
Write-Host "Validation complete." -ForegroundColor Green