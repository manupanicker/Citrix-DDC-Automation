Import-Module .\Modules\Common\Configuration.psm1 -Force

$config = Get-Configuration

Write-Host ""
Write-Host "===== Configuration Loaded =====" -ForegroundColor Cyan

Write-Host "Company               : $($config.Company)"
Write-Host "Environment           : $($config.Environment)"
Write-Host "Domain                : $($config.Domain)"

Write-Host ""
Write-Host "Citrix"

Write-Host "Site                  : $($config.Citrix.SiteName)"
Write-Host "Delivery Controller   : $($config.Citrix.DeliveryController)"
Write-Host "StoreFront            : $($config.Citrix.StoreFront)"
Write-Host "License Server        : $($config.Citrix.LicenseServer)"

Write-Host ""
Write-Host "SQL"

Write-Host "Server                : $($config.SQL.Server)"
Write-Host "Database              : $($config.SQL.Database)"

Write-Host ""
Write-Host "Logging"

Write-Host "Log File              : $($config.Logging.LogPath)"