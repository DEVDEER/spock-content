# init-secrets.ps1
# -------------------------------------------------------------------------------------
# Copyright DEVDEER GmbH 2026
# -------------------------------------------------------------------------------------
# If placed in a project root this will detect every csproj that has user secrets
# configured and a certain command in its Program.cs pointing toward a label in an
# Azure App Configuration. It will then reset and re-retrieve all user-secrets that
# are available for local development automatically. This can handle secrets of types
# plain text, KeyVault reference and JSON.
# -------------------------------------------------------------------------------------
# DISCLAIMER: This is for internal use in DEVDEER projects only. If you use this script
# we will not guarantee that the behavior is matching your internal security
# requirements. This uses the functionality of dotnet user-secrets which is not
# secure against local AIs which could potentially retrieve secrets in your user scope!
# -------------------------------------------------------------------------------------
# Latest update: 2026-07-29

[CmdletBinding()]
param (
    [switch]
    $ShowSecrets,
    [switch]
    $ShowSkipped
)

function FlattenJson {
    param(
        [Parameter(Mandatory)]
        [object]$Object,
        [string]$Prefix = ''
    )
    $result = @{ }
    if ($Object.GetType().BaseType.FullName -eq 'System.Array') {
        # the value is an array so the we need to add ":x" items
        $path = $Prefix -ne '' ? "$Prefix`:$key" : $key
        for ($i = 0; $i -lt $Object.Length; $i++) {
            $pathToTake = $path + "$i"
            $result[$pathToTake] = $Object[$i]
        }
    }
    else {
        foreach ($key in $Object.PSObject.Properties.Name) {
            $value = $Object.$key
            $path = if ($Prefix) {
                "$Prefix`:$key"
            }
            else {
                $key
            }
            if ($value -is [System.Management.Automation.PSCustomObject]) {
                $nested = FlattenJson -Object $value -Prefix $path
                $result += $nested
            }
            elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                for ($i = 0; $i -lt $value.Count; $i++) {
                    $nested = FlattenJson -Object $value[$i] -Prefix "$path`:$i"
                    $result += $nested
                }
            }
            else {
                $result[$path] = $value
            }
        }
    }
    return $result
}

function EnsureKey() {
    param (
        [Hashtable]
        $dict,
        [string]
        $key,
        [string]
        $val
    )
    if (!($dict.Keys -contains $key)) {
        $dict[$key] = @()
    }
    $dict[$key] += $val
}

function GetMappings() {
    $path = $PSScriptRoot
    $files = Get-ChildItem $path -Filter *.csproj -Recurse
    $pattern1 = '\.ConfigureDefaults\([^)]*"(.*?)"[^)]*\)'
    $pattern2 = '\.Select\(KeyFilter\.Any, \$"(.*)"\)'
    $mappings = @{}
    foreach ($file in $files) {
        [xml]$content = Get-Content -Raw $file
        if ($null -ne $content.Project.PropertyGroup.UserSecretsId) {
            $programFile = "$($file.Directory.FullName)/Program.cs"
            if (Test-Path $programFile) {
                $programContent = Get-Content -Raw $programFile
                EnsureKey -dict $mappings -key $file.Directory.FullName -val 'NONE'
                EnsureKey -dict $mappings -key $file.Directory.FullName -val 'Environment:Development'
                EnsureKey -dict $mappings -key $file.Directory.FullName -val 'Development'
                if ($programContent -match $pattern1) {
                    EnsureKey -dict $mappings -key $file.Directory.FullName -val $Matches[1]
                    EnsureKey -dict $mappings -key $file.Directory.FullName -val "$($Matches[1]):Environment:Development"
                    EnsureKey -dict $mappings -key $file.Directory.FullName -val "$($Matches[1]):Development"
                }
                elseif ($programContent -match $pattern2) {
                    EnsureKey -dict $mappings -key $file.Directory.FullName -val $Matches[1].Replace('{ctx.HostingEnvironment.EnvironmentName}', 'Development')
                }
            }
        }
    }
    $mappings
}

$ErrorActionPreference = 'Stop'
# get optional secrets file with black- and whitelist
$path = "$PSScriptRoot/secrets.json"
$secretsConfig = $null
if (Test-Path $path) {
    $secretsConfig = Get-Content -Raw $path | ConvertFrom-Json
    Write-Host "Using settings in $path"
}
$blackList = $secretsConfig.blackList ?? @('ConnectionStrings:')
$whiteList = $secretsConfig.whiteList ?? @()
# receive mappings for every appropriate project in the solution
$mappings = GetMappings
if ($mappings.Count -eq 0) {
    throw "No mappings available in this directory."
}
Write-Host "Found $($mappings.Count) projects to map:"
$mappings.Keys | ForEach-Object {
    Write-Host "   - $_"
}
$null = Use-CafContext
# hashtable with relative path to project folder and App Configuration label to use
$path = $PSScriptRoot
# if this command fails you are probably in the wrong subscription
$projectName = (Get-ChildItem -Filter *.sln?)[0].Name.Split('.')[0].ToLower()
Write-Host "Detecting App Configuration Store for project [$projectName]..." -NoNewline
try {
    $appConfigs = Get-AzAppConfigurationStore -ErrorAction SilentlyContinue
    $matching = $appConfigs | Where-Object { $_.Name.ToLower().Contains($projectName.ToLower()) }
    if ($matching.Length -gt 0) {
        $appConfigName = $matching[0].Name
    }
}
catch {
    Write-Host "Error (probably no valid AZ context)"  -ForegroundColor Red
    exit 1
}
if (!$appConfigName.Contains($projectName)) {
    throw 'Wrong app configuration detected. Check Get-AzContext'
}
Write-Host "[$appConfigName]" -ForegroundColor Green
$secrets = (Get-AzAppConfigurationKeyValue -Endpoint "https://$appConfigName.azconfig.io")
# cycle through each mapping key and call the user-secrets setting
foreach ($file in $mappings.Keys) {
    $currentProject = $file
    Write-Host "Setting secrets for project $currentProject."
    dotnet user-secrets clear --project $currentProject
    $currentProjectLabels = $mappings[$currentProject]
    Write-Host " -> $($currentProjectLabels -join ',')"
    foreach ($secret in $secrets) {
        $apply = $false
        # extract and clear the key and label from the secret
        $secretKey = $secret.Key
        $secretLabel = $secret.Label ?? 'NONE'
        if ($secretLabel.Length -eq 0) {
            $secretLabel = 'NONE'
        }
        # check if the the current label is part of the mapping for the project
        $apply = $currentProjectLabels -contains $secretLabel
        if (!$apply) {
            if ($ShowSkipped.IsPresent) {
                Write-Host "-> Skipping '$secretKey' with label '$secretLabel'" -ForegroundColor DarkGray
            }
            continue
        }
        # check if the current key is on the ignore list
        foreach ($ignore in $blackList) {
            if ($secretKey.StartsWith($ignore) -and (!($whiteList.Contains($secretKey)))) {
                $apply = $false
                break
            }
        }
        if (!$apply) {
            if ($ShowSkipped.IsPresent) {
                Write-Host "-> Skipping '$secretKey' with label '$secretLabel'" -ForegroundColor DarkGray
            }
            continue
        }
        # this secret should be applied
        if ($secret.ContentType.Contains('keyvaultref')) {
            # this is a KeyVault reference
            try {
                $json = $secret.Value | ConvertFrom-Json
                if ($json.uri -and ($json.uri -Match "https:\/\/(.*)\/secrets\/(.*)$")) {
                    # this is a key vault secret
                    $keyVaultName = $Matches[1].Split('.')[0]
                    $secretName = $Matches[2]
                    $secret.Value = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -AsPlainText
                    Write-Host "-> Retrieved secret '$secretKey' from KeyVault '$keyVaultName/$secretName'" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "Received non JSON value for '$secretKey' on label $secretLabel"
            }
        }
        if ($secret.ContentType -eq 'application/json') {
            # it is a JSON secret
            $json = $secret.Value | ConvertFrom-Json
            $flat = FlattenJson -object $json -Prefix $secretKey
            $flat.GetEnumerator() | ForEach-Object {
                $keyToTake = $_.Key.Replace('[', '').Replace(']', '.')
                dotnet user-secrets set $keyToTake $_.Value --project $currentProject | Out-Null
                Write-Host "-> Updated secret '$keyToTake'" -ForegroundColor Green
            }
            continue
        }
        # it is just plain text
        dotnet user-secrets set $secretKey $secret.Value --project $currentProject | Out-Null
        Write-Host "-> Updated secret '$secretKey' with label '$secretLabel'." -ForegroundColor Green
    }
    if ($ShowSecrets.IsPresent) {
        ## list out the secrets
        Write-Host "Secrets for project $($currentProject):"
        Write-Host "======================================================================"
        dotnet user-secrets list --project $currentProject
        Write-Host ''
    }
}
