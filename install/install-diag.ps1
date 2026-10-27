<#
.SYNOPSIS
    Diagnostics for installer share reachability. Exits on first failure.
    Does not install anything.

.EXAMPLE
    .\diag-share.ps1 -SharePath '\\storage.file.core.usgovcloudapi.net\installers' -FileName '7z-x64.msi'
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharePath = '\\sacimapps.file.core.usgovcloudapi.net\software\7zip',

    [Parameter(Mandatory = $true)]
    [string]$FileName = '7Zip-64bit.msi',

    [int]$TimeoutSeconds = 30,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    if (-not $script:LogPath) {
        $script:LogPath = Join-Path $env:TEMP ("DiagShare_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    }

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN' { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default { Write-Host $entry }
    }

    $logDir = Split-Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $script:LogPath -Value $entry
}

function Fail-Diag {
    param([string]$Message)
    Write-Log $Message -Level ERROR
    Write-Log 'Diagnostics failed' -Level ERROR
    exit 1
}

if ($LogPath) {
    $script:LogPath = $LogPath
}
else {
    $logDir = 'C:\ProgramData\SDL\scripts\logs'
    $script:LogPath = Join-Path $logDir ("DiagShare_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
}

$SharePath = $SharePath.TrimEnd('\')
$filePath = Join-Path $SharePath $FileName

Write-Log '===== Share diagnostics ====='
Write-Log "Share : $SharePath"
Write-Log "File  : $filePath"
Write-Log "Timeout : $TimeoutSeconds s"

try {
    # 1. UNC root reachable
    Write-Log 'Testing UNC root...'
    $shareJob = Start-Job -ScriptBlock {
        param($p)
        Test-Path -LiteralPath $p -ErrorAction Stop
    } -ArgumentList $SharePath

    if (-not (Wait-Job $shareJob -Timeout $TimeoutSeconds)) {
        Stop-Job $shareJob -Force | Out-Null
        Remove-Job $shareJob -Force | Out-Null
        Fail-Diag "UNC root timed out after $TimeoutSeconds s: $SharePath"
    }
    $shareOk = Receive-Job $shareJob
    Remove-Job $shareJob -Force | Out-Null
    if (-not $shareOk) {
        Fail-Diag "UNC root not reachable: $SharePath"
    }
    Write-Log 'UNC root reachable' -Level SUCCESS

    # 2. Directory listing
    Write-Log 'Listing share directory...'
    $dirJob = Start-Job -ScriptBlock {
        param($p)
        Get-ChildItem -LiteralPath $p -ErrorAction Stop | Select-Object -ExpandProperty Name
    } -ArgumentList $SharePath

    if (-not (Wait-Job $dirJob -Timeout $TimeoutSeconds)) {
        Stop-Job $dirJob -Force | Out-Null
        Remove-Job $dirJob -Force | Out-Null
        Fail-Diag "Directory list timed out after $TimeoutSeconds s: $SharePath"
    }
    $names = @(Receive-Job $dirJob)
    Remove-Job $dirJob -Force | Out-Null
    Write-Log ("Directory listed ({0} item(s))" -f $names.Count) -Level SUCCESS
    foreach ($n in ($names | Select-Object -First 20)) {
        Write-Log "  - $n"
    }

    # 3. File exists and can be opened
    Write-Log 'Testing file access...'
    $fileJob = Start-Job -ScriptBlock {
        param($p)
        if (-not (Test-Path -LiteralPath $p -ErrorAction Stop)) {
            throw "File not found: $p"
        }
        $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'Read')
        $len = $fs.Length
        $fs.Close()
        return $len
    } -ArgumentList $filePath

    if (-not (Wait-Job $fileJob -Timeout $TimeoutSeconds)) {
        Stop-Job $fileJob -Force | Out-Null
        Remove-Job $fileJob -Force | Out-Null
        Fail-Diag "File open timed out after $TimeoutSeconds s: $filePath"
    }
    $fileResult = Receive-Job $fileJob -ErrorAction SilentlyContinue
    $fileErr = $fileJob.ChildJobs[0].Error
    Remove-Job $fileJob -Force | Out-Null
    if ($fileErr) {
        Fail-Diag ("File access failed: {0}" -f $fileErr[0].Exception.Message)
    }
    Write-Log ("File opened, size {0} bytes" -f $fileResult) -Level SUCCESS

    Write-Log 'Diagnostics passed' -Level SUCCESS
    exit 0
}
catch {
    Fail-Diag $_.Exception.Message
}
