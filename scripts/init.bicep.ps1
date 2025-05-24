# This script installs the Nuget package devdeer.Templates.Bicep in the current directory
# and tries to clean it up afterwards.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2023-03-25
[CmdletBinding()]
param (
    [Parameter()]
    [switch]
    $PreRelease
)

if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot

$package = 'devdeer.templates.bicep'
$versionUrl = "https://api.nuget.org/v3-flatcontainer/$($package.ToLower())/index.json"
$result = Invoke-WebRequest -Uri $versionUrl
$json = $result.Content | ConvertFrom-Json
$pos = -1;
while ($true) {
    $version = $json.versions[$pos]
    if ($PreRelease.IsPresent) {
        break
    }
    if ($version.Contains('-') -eq $false) {
        break
    }
    $pos--
}
$packageNuget = "$($package.ToLower()).$($version.ToLower()).nupkg"
$downloadUrl = "https://api.nuget.org/v3-flatcontainer/$($package.ToLower())/$($version.ToLower())/$packageNuget"
Invoke-WebRequest -Uri $downloadUrl -OutFile $packageNuget
Expand-Archive $packageNuget tmp
Remove-Item $packageNuget
$folders = @( 'components', 'constants', 'functions', 'modules', 'types' )
if (!(Test-Path -Path "bicepSettings.json")) {
    Move-Item "$root/tmp/assets/bicepSettings.json" $root -Force
}
if (!(Test-Path -Path ".gitignore")) {
    Move-Item "$root/tmp/assets/.gitignore" $root -Force
}
foreach($folder in $folders) {
    if (Test-Path $folder) {
        Remove-Item -Force -Recurse $folder
    }
    Move-Item -Force "$root/tmp/$folder" $root
}
Remove-Item -Force -Recurse $root/tmp
Write-Host "Using version $version of devdeer.Template.Bicep now"

# download the scripts and content from GitHub
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/build.bicep.ps1" -OutFile "$root/build.bicep.ps1"