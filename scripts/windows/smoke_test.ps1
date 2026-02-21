[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8080',
    [int]$FreshnessThresholdSeconds = 1800,
    [string]$AuthToken = ''
)

$ErrorActionPreference = 'Stop'

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
