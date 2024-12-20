# This script installs the Nuget package devdeer.Templates.Bicep in the current directory
# and tries to clean it up afterwards.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2023-03-25

if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot

nuget install devdeer.Templates.Bicep -Source nuget.org -Prerelease -OutputDirectory $root

# remove existing modules and components
if (Test-Path -Path "$root/modules") {
    Remove-Item "$root/modules" -Recurse
}
if (Test-Path -Path "$root/components") {
    Remove-Item "$root/components" -Recurse
}
# move items modules and components one level up from the nuget path
Move-Item "$root/devdeer.Templates.Bicep*/modules" $root -Force
Move-Item "$root/devdeer.Templates.Bicep*/components" $root -Force
# try to remove the nuget installation package
Remove-Item "$root/devdeer.Templates.Bicep*" -Recurse -Force -ErrorAction SilentlyContinue

# download the scripts and content from GitHub
curl https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/deploy.bicep.ps1 -OutputDirectory $root
curl https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/build.bicep.ps1 -OutputDirectory $root
curl https://raw.githubusercontent.com/DEVDEER/spock-content/main/static/bicepContext.json -OutputDirectory $root