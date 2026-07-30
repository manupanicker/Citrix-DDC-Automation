function Get-Configuration {

    [CmdletBinding()]
    param(
        [string]$ConfigFile = "$PSScriptRoot\..\..\Config\Lab.json"
    )

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }

    $Configuration = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    return $Configuration
}

Export-ModuleMember -Function Get-Configuration