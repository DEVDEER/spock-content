# build-bicep.ps1
# -------------------------------------------------------------------------------------
# Copyright DEVDEER GmbH 2026
# -------------------------------------------------------------------------------------
# This file should be placed in the projects "infrastructure" folder named as
# `build.ps1`. It will try to execute `bicep build` on the main bicep and output
# the results in a directory "arm-output". It will write the sizes of the raw
# ARM JSON, the minified and the minified and zipped version to the output stream.
# -------------------------------------------------------------------------------------
# DISCLAIMER: This is for internal use in DEVDEER projects only. If you use this script
# we will not guarantee that the behavior is matching your internal security
# requirements. This uses the functionality of dotnet user-secrets which is not
# secure against local AIs which could potentially retrieve secrets in your user scope!
# -------------------------------------------------------------------------------------
# Latest update: 2026-10-09
$ErrorActionPreference = 'Stop'
if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot
# check if module devdeer.Caf is installed
if (!(Get-Module -ListAvailable -Name devdeer.Caf)) {
    Write-Host "Installing DEVDEER CAF module..."
    Install-PSResource -Name Devdeer.Caf -Repository PSGallery -Scope CurrentUser -TrustRepository
    Import-Module Devdeer.Caf
}
if (!(Test-Path "$root/modules")) {
    Write-Host "Installing DEVDEER Bicep modules..."
    Initialize-CafBicep
}
$(bicep -v) -match "version (.*) " 1>$null
$bicepVersion = $Matches[1]
Write-Host "Using Bicep version $bicepVersion."
$settingsJson = Get-Content -Raw $PSScriptRoot/bicepSettings.json | ConvertFrom-Json
if ($settingsJson.bicepMinVersion) {
    $currVersion = 0
    $minVersion = 0
    # calc current installed version value
    $i = 10000;
    $currParts = $bicepVersion.Split('.')
    foreach ($p in $currParts) {
        $i = $i / 100;
        $currVersion += [int]::Parse($p) * $i
    }
    # calc min tool version value
    $i = 10000;
    $minParts = $settingsJson.bicepMinVersion.Split('.')
    foreach ($p in $minParts) {
        $i = $i / 100;
        $minVersion += [int]::Parse($p) * $i
    }
    if ($currVersion -lt $minVersion) {
        Write-Warning "Current version $bicepVersion is smaller than minimum required version $($settingsJson.bicepMinVersion). Skipping."
        Exit 0
    }
    Write-Host "Current version $bicepVersion is greater or equal to minimum required version $($settingsJson.bicepMinVersion)"
}
$bicepFile = "$root/main.bicep"
$outFolder = "$root/arm-output"
$outFile = "$outFolder/main.json"
$minOutFile = "$outFolder/main.min.json"
$zipOutFile = "$outFolder/main.min.zip"
if (Test-Path -Path $outFolder) {
    $null = Remove-Item -Recurse -Force $outFolder
}
$null = mkdir $outFolder
bicep build $bicepFile --outfile $outFile
$content = Get-Content -Raw $outFile
($content | ConvertFrom-Json -Depth 100 | ConvertTo-Json -Depth 100 -Compress) | Set-Content $minOutFile
$minContent = Get-Content -Raw $minOutFile
Compress-Archive -Path $minOutFile -DestinationPath $zipOutFile
$zipContent = Get-Content -Raw $zipOutFile
$bytes = $content.Length
$minBytes = $minContent.Length
$zipBytes = $zipContent.Length
Write-Host "Generated $outFile with length $($bytes.ToString("#,###")) bytes."
Write-Host "Minified $minOutFile with length $($minBytes.ToString("#,###")) bytes."
Write-Host "Compressed $zipOutFile with length $($zipBytes.ToString("#,###")) bytes."
if (!$?) {
    # Ensure that exit code of script is reflecting failed Bicep
    throw "Bicep error"
}