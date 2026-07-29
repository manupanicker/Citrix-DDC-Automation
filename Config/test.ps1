Import-Module .\Modules\Common\Logging.psm1 -Force

Write-Log -Message "Starting validation"
Write-Log -Message "Checking PowerShell version" -Level INFO
Write-Log -Message "Low disk space detected" -Level WARNING
Write-Log -Message "Unable to contact SQL Server" -Level ERROR
Write-Log -Message "Validation completed successfully" -Level SUCCESS