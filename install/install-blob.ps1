<#
.SYNOPSIS
    Blob reachability check for AIB. Gets a managed-identity token and
    downloads the blob over HTTPS. Windows PowerShell 5.1.
    Accepts -Force so the master installer can call it.

.EXAMPLE
    .\install-diag.ps1 -Force
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$BlobUrl = 'https://saavdsoft.blob.core.usgovcloudapi.net/software/7Zip/7Zip-64bit.msi',

    [int]$TimeoutSeconds = 30,

    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line
    [Console]::Out.Flush()
}

function Fail-Diag {
    param([string]$Message)
    Write-Log $Message 'ERROR'
    Write-Log 'RESULT: FAILED' 'ERROR'
    exit 1
}

Write-Log '===== Blob diagnostics ====='
Write-Log "Blob : $BlobUrl"

$uri = $null
try { $uri = [uri]$BlobUrl } catch { Fail-Diag "Bad URL: $BlobUrl" }
$hostName = $uri.Host

Write-Log "Resolving $hostName"
try {
    $ips = @([System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString })
    Write-Log ("Resolved: {0}" -f ($ips -join ', ')) 'SUCCESS'
}
catch {
    Fail-Diag "DNS failed for ${hostName}: $($_.Exception.Message). Link privatelink.blob.core.usgovcloudapi.net to the build VNet."
}

Write-Log "Testing TCP 443 to $hostName"
$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $iar = $tcp.BeginConnect($hostName, 443, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000, $false)) {
        Fail-Diag "TCP 443 timed out after $TimeoutSeconds s. Private endpoint or NSG is blocking the build subnet."
    }
    $tcp.EndConnect($iar)
    Write-Log 'TCP 443 open' 'SUCCESS'
}
catch {
    Fail-Diag "TCP 443 failed: $($_.Exception.Message)"
}
finally {
    $tcp.Close()
}

Write-Log 'Requesting managed identity token'
$tokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.usgovcloudapi.net%2F'
try {
    $tokenResponse = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Uri $tokenUri -TimeoutSec $TimeoutSeconds
    if (-not $tokenResponse.access_token) {
        Fail-Diag 'Managed identity returned no access token. Confirm the AIB identity is attached to the build VM.'
    }
    Write-Log 'Token acquired' 'SUCCESS'
    if ($tokenResponse.client_id) {
        Write-Log "Token client_id : $($tokenResponse.client_id)"
    }
    $payload = $tokenResponse.access_token.Split('.')[1]
    $pad = 4 - ($payload.Length % 4)
    if ($pad -ne 4) { $payload += ('=' * $pad) }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace('-', '+').Replace('_', '/')))
    $claims = $json | ConvertFrom-Json
    Write-Log "Token oid     : $($claims.oid)"
    Write-Log "Token appid   : $($claims.appid)"
    Write-Log "Token aud     : $($claims.aud)"
}
catch {
    Fail-Diag "Token request failed: $($_.Exception.Message). Confirm the AIB user-assigned identity is on the build VM."
}
$dest = Join-Path $env:TEMP '7Zip-64bit.msi'
if (Test-Path $dest) { Remove-Item $dest -Force }

Write-Log 'Downloading blob'
try {
    Invoke-WebRequest -Uri $BlobUrl -Headers @{ Authorization = "Bearer $($tokenResponse.access_token)"; 'x-ms-version' = '2021-08-06' } -OutFile $dest -TimeoutSec 120 -UseBasicParsing
}
catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    if ($code -eq 403) {
        Fail-Diag 'Download failed: 403. Grant the AIB identity Storage Blob Data Reader on the software container.'
    }
    if ($code -eq 404) {
        Fail-Diag 'Download failed: 404. Blob path not found. Expected container software, path 7Zip/7Zip-64bit.msi.'
    }
    Fail-Diag "Download failed ($code): $($_.Exception.Message)"
}

if (-not (Test-Path $dest)) {
    Fail-Diag "Download reported success but file is missing: $dest"
}
$size = (Get-Item $dest).Length
if ($size -lt 1) {
    Fail-Diag 'Downloaded file is empty.'
}

Write-Log "Blob downloaded, size $size bytes" 'SUCCESS'
Write-Log "Saved: $dest"
Write-Log 'Diagnostics passed' 'SUCCESS'
exit 0