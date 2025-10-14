function Flatten-Json {
    param(
        [Parameter(Mandatory)]
        [object]$Object,
        [string]$Prefix = ''
    )
    $result = @{}
    foreach ($key in $Object.PSObject.Properties.Name) {
        $value = $Object.$key
        $path = if ($Prefix) { "$Prefix`:$key" } else { $key }
        if ($value -is [System.Management.Automation.PSCustomObject]) {
            $nested = Flatten-Json -Object $value -Prefix $path
            $result += $nested
        }
        elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            for ($i = 0; $i -lt $value.Count; $i++) {
                $nested = Flatten-Json -Object $value[$i] -Prefix "$path`:$i"
                $result += $nested
            }
        }
        else {
            $result[$path] = $value
        }
    }

    return $result
}

$ErrorActionPreference = 'Stop'
Use-CafContext
# Hashtable with relative path to project folder and App Configuration label to use
$mappings = @{
    './src/Services/Services.CoreApi/' = @($null, 'Environment.Development', 'Core:Environment:Development')
}
# Array of keys to not apply from App Configuration
$ignoreList = @(
    'ConnectionStrings:Griffin'
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
    $currentProject = $_
    Write-Host "Setting secrets for project $currentProject."
    dotnet user-secrets clear --project $currentProject
    $labels = $mappings[$currentProject]
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
        if ($secret.ContentType.Contains('keyvaultref')) {
            # this is a KeyVault reference
            $json = $secret.Value | ConvertFrom-Json
            if ($json.uri -and ($json.uri -Match "https:\/\/(.*)\/secrets\/(.*)$")) {
                # this is a key vault secret
                $keyVaultName = $Matches[1].Split('.')[0]
                $secretName = $Matches[2]
                $secret.Value = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -AsPlainText
                Write-Host "-> Retrieved secret $($secret.Key) from KeyVault $keyVaultName/$secretName" -ForegroundColor Green
            }
        }
        if ($secret.ContentType -eq 'application/json') {
            # it is a JSON secret
            $json = $secret.Value | ConvertFrom-Json
            $flat = Flatten-Json -object $json -Prefix $secret.Key
            $flat
            $flat.GetEnumerator() | ForEach-Object {
                dotnet user-secrets set "$_.Key" "$_.Value" --project $currentProject | Out-Null
                Write-Host "-> Updated secret $($_.Key)" -ForegroundColor Green
            }
            continue
        }
        # it is just plain text
        dotnet user-secrets set $secret.Key $secret.Value --project $currentProject | Out-Null
        Write-Host "-> Updated secret $($secret.Key)" -ForegroundColor Green
    }
    ## list out the secrets
    Write-Host "Secrets for project $($_):"
    Write-Host "======================================================================"
    dotnet user-secrets list --project $_
    Write-Host ''
}



