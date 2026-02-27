[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [int]$FreshnessThresholdSeconds = 1800,
    [string]$AuthToken = ''
)

$ErrorActionPreference = 'Stop'


function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if (-not (Test-Path $EnvPath)) {
        return $null
    }

    foreach ($line in Get-Content -Path $EnvPath) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Length -eq 2 -and $pair[0].Trim() -eq $Key) {
            return $pair[1].Trim()
        }
    }

    return $null
}

if (-not $BaseUrl) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\.." )).Path
    $envPath = Join-Path $repoRoot '.env'
    $dashboardPort = Get-EnvValue -EnvPath $envPath -Key 'DASHBOARD_PORT'
    if (-not $dashboardPort) {
        $dashboardPort = '8080'
    }
    $BaseUrl = "http://localhost:$dashboardPort"
}


$headers = @{}
if ($AuthToken) {
    $headers['X-Auth-Token'] = $AuthToken
}

$response = Invoke-RestMethod -Method Get -Uri "$BaseUrl/api/health" -Headers $headers
if (-not $response) {
    throw 'No response payload from /api/health'
}

if ($null -eq $response.secondsSinceLatest) {
    throw '/api/health returned null secondsSinceLatest (no interval data yet?)'
}

$seconds = [int]$response.secondsSinceLatest
if ($seconds -gt $FreshnessThresholdSeconds) {
    throw "Dashboard stale: secondsSinceLatest=$seconds threshold=$FreshnessThresholdSeconds"
}

Write-Host "PASS health endpoint reachable; secondsSinceLatest=$seconds"
Write-Host ("latestIntervalEnd=" + $response.latestIntervalEnd)
