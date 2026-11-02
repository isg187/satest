# <#
# .SYNOPSIS
#     Share reachability check for AIB. Logs to stdout. Exits 1 on first failure.
#     Windows PowerShell 5.1. Accepts -Force so the master installer can call it.

# .EXAMPLE
#     .\install-diag.ps1 -Force
# #>

# #Requires -Version 5.1

# [CmdletBinding()]
# param(
#     [string]$SharePath = '\\sacimapps.file.core.usgovcloudapi.net\software\7zip',

#     [string]$FileName = '7Zip-64bit.msi',

#     [int]$TimeoutSeconds = 30,

#     [switch]$Force
# )

# $ErrorActionPreference = 'Continue'
# $ProgressPreference = 'SilentlyContinue'

# function Write-Log {
#     param([string]$Message, [string]$Level = 'INFO')
#     $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
#     Write-Output $line
#     [Console]::Out.Flush()
# }

# function Fail-Diag {
#     param([string]$Message)
#     Write-Log $Message 'ERROR'
#     Write-Log 'RESULT: FAILED' 'ERROR'
#     exit 1
# }

# function Invoke-Cmd {
#     param(
#         [string]$Arguments,
#         [string]$Label
#     )

#     $out = Join-Path $env:TEMP ("diag-{0}.out" -f [guid]::NewGuid().ToString('N'))
#     $err = Join-Path $env:TEMP ("diag-{0}.err" -f [guid]::NewGuid().ToString('N'))

#     $psi = New-Object System.Diagnostics.ProcessStartInfo
#     $psi.FileName = "$env:SystemRoot\System32\cmd.exe"
#     $psi.Arguments = $Arguments
#     $psi.UseShellExecute = $false
#     $psi.CreateNoWindow = $true
#     $psi.RedirectStandardOutput = $true
#     $psi.RedirectStandardError = $true

#     $proc = New-Object System.Diagnostics.Process
#     $proc.StartInfo = $psi
#     $proc.Start() | Out-Null

#     $outTask = $proc.StandardOutput.ReadToEndAsync()
#     $errTask = $proc.StandardError.ReadToEndAsync()
#     if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
#         try { $proc.Kill() } catch {}
#         Fail-Diag "$Label timed out after $TimeoutSeconds s"
#     }
#     $proc.WaitForExit()

#     $text = ''
#     try { $text = $outTask.Result } catch {}
#     try {
#         $errText = $errTask.Result
#         if ($errText) { $text = ($text + ' ' + $errText).Trim() }
#     }
#     catch {}

#     return [pscustomobject]@{
#         ExitCode = $proc.ExitCode
#         Text     = $text
#     }
# }

# $SharePath = $SharePath.TrimEnd('\')
# $filePath = Join-Path $SharePath $FileName

# Write-Log '===== Share diagnostics ====='
# Write-Log "Share : $SharePath"
# Write-Log "File  : $filePath"

# $hostName = ($SharePath -replace '^\\\\', '' -split '\\')[0]
# if (-not $hostName) {
#     Fail-Diag "Could not parse host from $SharePath"
# }

# Write-Log "Resolving $hostName"
# try {
#     $ips = @([System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString })
#     Write-Log ("Resolved: {0}" -f ($ips -join ', ')) 'SUCCESS'
# }
# catch {
#     Fail-Diag "DNS failed for ${hostName}: $($_.Exception.Message)"
# }

# Write-Log "Testing TCP 445 to $hostName"
# $tcp = New-Object System.Net.Sockets.TcpClient
# try {
#     $iar = $tcp.BeginConnect($hostName, 445, $null, $null)
#     if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000, $false)) {
#         Fail-Diag "TCP 445 timed out after $TimeoutSeconds s. Private endpoint or NSG is blocking the build subnet."
#     }
#     $tcp.EndConnect($iar)
#     Write-Log 'TCP 445 open' 'SUCCESS'
# }
# catch {
#     Fail-Diag "TCP 445 failed: $($_.Exception.Message)"
# }
# finally {
#     $tcp.Close()
# }

# Write-Log 'Listing directory'
# $dir = Invoke-Cmd -Label 'Directory list' -Arguments "/c dir /b `"$SharePath`""
# if ($dir.ExitCode -ne 0) {
#     Fail-Diag "Directory list failed (exit $($dir.ExitCode)): $($dir.Text)"
# }
# Write-Log 'Directory listed' 'SUCCESS'
# ($dir.Text -split "`r?`n" | Where-Object { $_ } | Select-Object -First 20) | ForEach-Object { Write-Log "  - $_" }

# Write-Log 'Opening file'
# $file = Invoke-Cmd -Label 'File open' -Arguments "/c if exist `"$filePath`" (echo OK) else (echo MISSING & exit /b 2)"
# if ($file.ExitCode -ne 0) {
#     Fail-Diag "File check failed (exit $($file.ExitCode)): $($file.Text)"
# }
# Write-Log 'File exists and is reachable' 'SUCCESS'
# Write-Log 'Diagnostics passed' 'SUCCESS'
# exit 0
