<#
.SYNOPSIS
    Diagnostics for installer share reachability. Exits on first failure.
    Does not install anything.

.EXAMPLE
    .\diag-share.ps1 -SharePath '\\storage.file.core.usgovcloudapi.net\installers' -FileName '7z-x64.msi'
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SharePath = '\\sacimapps.file.core.usgovcloudapi.net\software\7zip',

    [Parameter(Mandatory = $true)]
    [string]$FileName = '7Zip-64bit.msi',

    [int]$TimeoutSeconds = 30
)

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
    [Console]::Out.Flush()
    Add-Content -Path $log -Value $line
}

function Invoke-TimedProcess {
    param(
        [string]$File,
        [string]$Arguments,
        [string]$Label
    )

    $out = Join-Path $env:TEMP ("diag-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $out
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch {}
        Write-Log "$Label timed out after $TimeoutSeconds s" 'ERROR'
        exit 1
    }
    $text = ''
    if (Test-Path $out) {
        $text = Get-Content $out -Raw -ErrorAction SilentlyContinue
        Remove-Item $out -Force -ErrorAction SilentlyContinue
    }
    if ($p.ExitCode -ne 0) {
        Write-Log "$Label failed (exit $($p.ExitCode)): $text" 'ERROR'
        exit 1
    }
    return $text
}

$SharePath = $SharePath.TrimEnd('\')
$filePath = Join-Path $SharePath $FileName

Write-Log '===== Share diagnostics ====='
Write-Log "Share : $SharePath"
Write-Log "File  : $filePath"

if ($SharePath -match '<storage>' -or $FileName -match '<installer') {
    Write-Log 'SharePath or FileName is still the placeholder. Set both before running.' 'ERROR'
    exit 1
}

# Host from \\server\share\...
$hostName = ($SharePath -replace '^\\\\', '' -split '\\')[0]
Write-Log "Resolving $hostName"
try {
    $ips = [System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString }
    Write-Log ("Resolved: {0}" -f ($ips -join ', ')) 'SUCCESS'
}
catch {
    Write-Log "DNS failed for ${hostName}: $($_.Exception.Message)" 'ERROR'
    exit 1
}

Write-Log "Testing TCP 445 to $hostName"
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $iar = $tcp.BeginConnect($hostName, 445, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000, $false)) {
        Write-Log "TCP 445 timed out after $TimeoutSeconds s" 'ERROR'
        exit 1
    }
    $tcp.EndConnect($iar)
    Write-Log 'TCP 445 open' 'SUCCESS'
}
catch {
    Write-Log "TCP 445 failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    $tcp.Close()
}

Write-Log 'Listing directory'
$dirOut = Invoke-TimedProcess -Label 'Directory list' -File 'cmd.exe' -Arguments "/c dir /b `"$SharePath`""
Write-Log 'Directory listed' 'SUCCESS'
($dirOut -split "`r?`n" | Where-Object { $_ } | Select-Object -First 20) | ForEach-Object { Write-Log "  - $_" }

Write-Log 'Opening file'
$null = Invoke-TimedProcess -Label 'File open' -File 'cmd.exe' -Arguments "/c if exist `"$filePath`" (echo OK) else (exit /b 2)"
Write-Log 'File exists and is reachable' 'SUCCESS'
Write-Log 'Diagnostics passed' 'SUCCESS'
exit 0