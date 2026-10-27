<#
.SYNOPSIS
    Diagnostics for installer share reachability. Exits on first failure.
    Does not install anything.

.EXAMPLE
    .\diag-share.ps1 -SharePath '\\storage.file.core.usgovcloudapi.net\installers' -FileName '7z-x64.msi'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharePath = '\\sacimapps.file.core.usgovcloudapi.net\software\7zip',

    [Parameter(Mandatory = $true)]
    [string]$FileName = '7Zip-64bit.msi',

    [int]$TimeoutSeconds = 30
)

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$logDir = 'C:\ProgramData\SDL\scripts\logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$log = Join-Path $logDir ("DiagShare_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $log -Value $line
}

function Invoke-Timed {
    param(
        [scriptblock]$Script,
        [object[]]$ArgumentList,
        [string]$Label
    )

    $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgumentList
    $done = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $done) {
        Stop-Job -Job $job | Out-Null
        Remove-Job -Job $job -Force | Out-Null
        Write-Log "$Label timed out after $TimeoutSeconds s" 'ERROR'
        exit 1
    }

    $output = Receive-Job -Job $job 2>&1
    $state = $job.State
    Remove-Job -Job $job -Force | Out-Null

    if ($state -eq 'Failed') {
        Write-Log "$Label failed: $output" 'ERROR'
        exit 1
    }

    return $output
}

$SharePath = $SharePath.TrimEnd('\')
$filePath = Join-Path $SharePath $FileName

Write-Log '===== Share diagnostics ====='
Write-Log "Share : $SharePath"
Write-Log "File  : $filePath"

# 1. UNC root
Write-Log 'Testing UNC root'
$shareOk = Invoke-Timed -Label 'UNC root' -ArgumentList $SharePath -Script {
    param($p)
    Test-Path -LiteralPath $p
}
if (-not $shareOk) {
    Write-Log "UNC root not reachable: $SharePath" 'ERROR'
    exit 1
}
Write-Log 'UNC root reachable' 'SUCCESS'

# 2. Directory list
Write-Log 'Listing directory'
$names = @(Invoke-Timed -Label 'Directory list' -ArgumentList $SharePath -Script {
        param($p)
        (Get-ChildItem -LiteralPath $p | Select-Object -ExpandProperty Name)
    })
Write-Log ("Directory listed ({0} item(s))" -f $names.Count) 'SUCCESS'
foreach ($n in ($names | Select-Object -First 20)) {
    Write-Log "  - $n"
}

# 3. Open file
Write-Log 'Opening file'
$size = Invoke-Timed -Label 'File open' -ArgumentList $filePath -Script {
    param($p)
    if (-not (Test-Path -LiteralPath $p)) {
        throw "File not found: $p"
    }
    $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'Read')
    $len = $fs.Length
    $fs.Dispose()
    $len
}
Write-Log "File opened, size $size bytes" 'SUCCESS'
Write-Log 'Diagnostics passed' 'SUCCESS'
exit 0
