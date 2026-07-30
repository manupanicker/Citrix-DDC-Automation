function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO',

        [string]$LogFile
    )

    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] [$Level] $Message"

    switch ($Level) {
        'INFO'    { $Color = 'White' }
        'WARNING' { $Color = 'Yellow' }
        'ERROR'   { $Color = 'Red' }
        'SUCCESS' { $Color = 'Green' }
    }

    Write-Host $LogEntry -ForegroundColor $Color

    if ($LogFile) {
        Add-Content -Path $LogFile -Value $LogEntry
    }
}
function Write-ValidationResult {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [string]$SuccessMessage = "Passed",

        [string]$FailureMessage = "Failed"
    )

    if ($Passed) {
        Write-Log "$Check - $SuccessMessage" -Level SUCCESS
    }
    else {
        Write-Log "$Check - $FailureMessage" -Level ERROR
    }
}
Export-ModuleMember -Function Write-Log, Write-ValidationResult