# This represents the default Endpoint Health check used by CD pipelines
# in our customer projects when deploy slots are used. It tries to call the
# /health endpoint on the deploy stage of an app. If it receives 200 it also
# checks if the resulting JSON has an overall state of "Healthy". It will return
# 0 on sucess or 1 on any failure so that the CD process can understand if
# the test was successful.
#
# Copyright DEVDEER GmbH 2025
# Latest update: 2025-02-03

[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $AppName,
    [Parameter()]
    [string]
    [ValidateSet('int', 'test', 'prod')]
    $Stage,
    [Parameter()]
    [string]
    $HealthCheckPath = "health",
    [Parameter()]
    [int]
    $MaxRetries = 10,
    [switch]
    $NoContentCheck
)
Write-Host "Trying to retrieve response from API on Slot..."
$tries = 0
$url = "https://$AppName-$Stage-deploy.azurewebsites.net"
if ($HealthCheckPath -ne '/') {
    $url += "/$HealthCheckPath"
}
$statusOk = $false
while ($tries -lt $MaxRetries -and !$statusOk) {
    $tries++
    Start-Sleep -Seconds 5    
    Write-Host "Sending request to $url ($tries of $MaxRetries times) ... " -NoNewLine
    try {
        $response = Invoke-WebRequest $url
        $apiState = $response.StatusCode
        Write-Host "OK $apiState" -ForegroundColor Green
        if ($apiState -eq 200) {
            if ($NoContentCheck.IsPresent) {
                $statusOk = $true
                Write-Host "Endpoint responding." -ForegroundColor Green
                continue
            }
            # check response JSON
            $json = $response.Content | ConvertFrom-Json
            $statusOk = $json.OverallStatus -eq 'Healthy'
            if (!$statusOk) {
                Write-Host "Health check responded with UNHEALTHY state." -ForegroundColor Yellow
            }
            else {
                Write-Host "Health check responded with HEALTHY state" -ForegroundColor Green
            }
        }
    }
    catch {
        # ignore
        Write-Host "ERROR" -ForegroundColor Red
    }
}

if ($statusOk) {
    $ExitCode = 0
}
else {
    $ExitCode = 1
}
Exit $ExitCode
