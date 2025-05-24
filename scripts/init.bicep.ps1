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

$root = "."
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
Write-Host "Downloaded version $version of devdeer.Template.Bicep."
# move file assets from package out
if (!(Test-Path -Path "bicepSettings.json")) {
    Move-Item "$root/tmp/assets/bicepSettings.json" $root -Force
}
if (!(Test-Path -Path ".gitignore")) {
    Move-Item "$root/tmp/assets/.gitignore" $root -Force
}
# move folders from packages out
$folders = @( 'components', 'constants', 'functions', 'modules', 'types' )
foreach($folder in $folders) {
    if (Test-Path "$root/$folder") {
        Remove-Item -Force -Recurse $folder
    }
    Move-Item -Force "$root/tmp/$folder" $root
}
# cleanup
Remove-Item -Force -Recurse $root/tmp
Write-Host "Using version $version of devdeer.Template.Bicep now"
# download the scripts and content from GitHub
#Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/build.bicep.ps1" -OutFile "$root/build.ps1"
Get-ChildItem $root