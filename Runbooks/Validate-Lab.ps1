Import-Module "$PSScriptRoot\..\Modules\Common\Logging.psm1" -Force
Import-Module "$PSScriptRoot\..\Modules\Common\Configuration.psm1" -Force
Import-Module "$PSScriptRoot\..\Modules\Validation\Validation.psm1" -Force

$config = Get-Configuration

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " AlphaQ Infrastructure Validation"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

Write-Log "Starting validation"

if (Test-PowerShellVersion) {
    Write-Log "PowerShell Version OK" -Level SUCCESS
}
else {
    Write-Log "PowerShell 7 or later is required." -Level ERROR
}

if (Test-Administrator) {
    Write-Log "Running as Administrator" -Level SUCCESS
}
else {
    Write-Log "Not running as Administrator" -Level ERROR
}
Write-ValidationResult `
    -Check "WinRM" `
    -Passed (Test-WinRM) `
    -SuccessMessage "Service Running" `
    -FailureMessage "Service Not Running"

$Disk = Test-DiskSpace

if ($Disk.Passed) {
    Write-Log "C: Drive Free Space: $($Disk.FreeGB) GB" -Level SUCCESS
}
else {
    Write-Log "Only $($Disk.FreeGB) GB free on C: drive" -Level ERROR
}

$OS = Test-OperatingSystem

if ($OS.Passed) {
    Write-Log "Operating System: $($OS.Name) ($($OS.Version))" -Level SUCCESS
}
else {
    Write-Log "Unsupported Operating System: $($OS.Name)" -Level ERROR
}

$Reboot = Test-PendingReboot

if ($Reboot.Passed) {
    Write-Log "No pending reboot detected" -Level SUCCESS
}
else {
    Write-Log "Pending reboot detected" -Level ERROR
}

Write-Log "Configuration loaded for $($config.Company)" -Level SUCCESS

Write-Host ""
Write-Host "Validation complete." -ForegroundColor Green