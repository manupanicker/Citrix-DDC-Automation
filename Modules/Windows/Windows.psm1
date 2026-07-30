function Get-RequiredWindowsFeatures {

    [CmdletBinding()]
    param()

    return @(
        "NET-Framework-45-Core",
        "NET-Framework-45-ASPNET",
        "Web-Server",
        "Web-WebServer",
        "Web-Common-Http",
        "Web-Default-Doc",
        "Web-Static-Content",
        "Web-Http-Errors",
        "Web-Http-Redirect",
        "Web-Health",
        "Web-Http-Logging",
        "Web-Performance",
        "Web-Stat-Compression",
        "Web-Security",
        "Web-Filtering",
        "Web-Windows-Auth",
        "Web-App-Dev",
        "Web-Net-Ext45",
        "Web-Asp-Net45",
        "Web-ISAPI-Ext",
        "Web-ISAPI-Filter",
        "Web-Mgmt-Tools",
        "Web-Mgmt-Console"
    )
}

function Test-WindowsFeatures {

    [CmdletBinding()]
    param()

    $RequiredFeatures = Get-RequiredWindowsFeatures

    $Results = foreach ($Feature in $RequiredFeatures) {

        $FeatureInfo = Get-WindowsFeature -Name $Feature

        [PSCustomObject]@{
            Name      = $Feature
            Installed = $FeatureInfo.Installed
        }
    }

    return $Results
}

Export-ModuleMember -Function Get-RequiredWindowsFeatures, Test-WindowsFeatures