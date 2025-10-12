$ErrorActionPreference = 'Stop'
Use-CafContext | Out-Null
# TODO: Configure the hash table
# Hashtable with relative path to project folder and App Configuration label to use
$mappings = @{
    './src/Services/Services.CoreApi/' = @($null, 'Environment.Development', 'Core:Environment:Development')
}
# Array of keys to not apply from App Configuration
$ignoreList = @(
    'ConnectionStrings'
)
# If this command fails you are probably in the wrong subscription
$projectName = (Get-ChildItem -Filter *.sln?)[0].Name.Split('.')[0].ToLower()
Write-Host "Detecting App Configuration Store for project [$projectName]..." -NoNewline
$appConfigName = (Get-AzAppConfigurationStore)[0].Name
if (!$appConfigName.Contains($projectName)) {
    throw 'Wrong app configuration detected. Check Get-AzContext'
}
Write-Host "[$appConfigName]" -ForegroundColor Green

$mappings.Keys | ForEach-Object {
    Write-Host "Setting secrets for project $_."
    dotnet user-secrets clear --project $_
    $labels = $mappings[$_]
    $secrets = (Get-AzAppConfigurationKeyValue -Endpoint "https://$appConfigName.azconfig.io")
    foreach ($secret in $secrets) {
        $apply = $false
        # check if the the current label is part of the mapping for the project
        foreach($label in $labels) {
            if ($label -eq $secret.Label) {
                $apply = $true
                break
            }
        }
        if (!$apply) {
            Write-Host "-> Skipping $($secret.Key) with label $($secret.Label)" -ForegroundColor DarkGray
            continue
        }
        # check if the current key is on the ignore list
        foreach($ignore in $ignoreList) {
            if ($secret.Key.StartsWith($ignore)) {
                $apply = $false
                break
            }
        }
        if (!$apply) {
            Write-Host "-> Skipping $($secret.Key) with label $($secret.Label)" -ForegroundColor DarkGray
            continue
        }
        # this secret should be applied
        dotnet user-secrets set $secret.Key $secret.Value --project $_ | Out-Null
        Write-Host "-> Updated secret $($secret.Key)" -ForegroundColor Green
    }
    ## list out the secrets
    Write-Host "Secrets for project $($_):"
    Write-Host "======================================================================"
    dotnet user-secrets list --project $_
    Write-Host ''
}
