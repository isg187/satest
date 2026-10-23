#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath = '\\sacimapps.file.core.usgovcloudapi.net\software\7zip\7Zip-64bit.msi',

    [string]$LogPath = 'C:\ProgramData\SDL\scripts\logs',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$logFile = Join-Path $LogPath ("install-7zip_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'ERROR', 'WARN')]
        [string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $logFile -Value $line
    Write-Host $line
}

function Test-7ZipInstalled {
    $paths = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

try {
    Write-Log 'Starting 7-Zip install'
    Write-Log "SourcePath: $SourcePath"

    if (-not (Test-Path $SourcePath)) {
        throw "Installer not found: $SourcePath"
    }

    if ((Test-7ZipInstalled) -and -not $Force) {
        Write-Log '7-Zip already installed' -Level SUCCESS
        exit 0
    }

    $args = @(
        '/i',
        "`"$SourcePath`"",
        '/qn',
        '/norestart'
    )

    Write-Log 'Running msiexec'
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow

    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
        Write-Log "Install completed with exit code $($p.ExitCode)" -Level SUCCESS
    }
    else {
        throw "msiexec returned exit code $($p.ExitCode)"
    }

    if (Test-7ZipInstalled) {
        Write-Log '7-Zip verified' -Level SUCCESS
    }
    else {
        Write-Log 'Install finished but 7z.exe was not found' -Level WARN
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" -Level ERROR
    exit 1
}