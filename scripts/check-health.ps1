[CmdletBinding()]
param (
	[Parameter()]
	[string]	
	$AppName,
	[Parameter()]
	[string]
	[ValidateSet('int', 'test', 'prod')]
	$Stage
)

Write-Host "Trying to retrieve response from API on Slot..."
$maxTries = 10
$tries = 0
$url = "https://$AppName-$Stage-deploy.azurewebsites.net/health"
$statusOk = $false
while ($tries -lt $maxTries) {
	$tries++
	Start-Sleep -Seconds 5
	Write-Host "Sending request to $url ($tries of $maxTries times) ... " -NoNewLine
	try {
		$response = Invoke-WebRequest $url
		$apiState = $response.StatusCode
		Write-Host "API responded with HTTP Status $apiState" -ForegroundColor Green
		if ($apiState -eq 200) {
			# check response JSON
			$json = $response.Content | ConvertFrom-Json
			$statusOk = $json.OverallStatus -eq 'Healthy'
			if (!$statusOk) {
				Write-Host "WARN: API responded with UNHEALTHY state." -ForegroundColor Yellow
			}
			else {
				Write-Host "OK: API responded with HEALTHY state" -ForegroundColor Green
			}
			# break the loop
			$tries = $maxTries
		} 
	}
	catch {
		# ignore		
		Write-Host "ERROR: No response retrieved." -ForegroundColor Red 
	}	
}

$ExitCode = ($statusOk) ? 0 : 1
Exit $ExitCode