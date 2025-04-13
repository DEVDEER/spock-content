[CmdLetBinding()]
param (
    [switch]
    $Prerelease
)
# !!! We need to change directory because -OutputDirectory of nuget install will ignore the current
# script root !!!
if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot
# check if nuget feed is registered as package source
$provider = Get-PsResourceRepository -Name nuget.org -ErrorAction SilentlyContinue
if ($null -eq $provider) {
    Register-PSResourceRepository -Name nuget.org -Uri https://api.nuget.org/v3/index.json `
        -Trusted `
        -Force
}
if ($Prerelease.IsPresent) {
    $version = Find-PSResource -Name devdeer.Templates.Bicep -Repository nuget.org -Prerelease | Where-Object { $_.Name -eq 'devdeer.Templates.Bicep' }
    # Combine the version with the prerelease tag
    $version = $version.Version.ToString() + '-' + $version.Prerelease.ToString()
    Write-Host "Downloading prerelease version: $version"
}
else {
    $version = (Find-PSResource -Name devdeer.Templates.Bicep -Repository nuget.org | Where-Object { $_.Name -eq 'devdeer.Templates.Bicep' }).Version.ToString()
    Write-Host "Downloading version: $version"
}
# download the modules and components
Save-PSResource -Name "devdeer.Templates.Bicep" `
    -Version $version `
    -Repository nuget.org `
    -Path $PSScriptRoot `
    -TrustRepository
$folders = @('modules', 'components', 'constants', 'functions', 'types')
foreach ($folder in $folders) {
    # remove existing modules and components
    if (Test-Path -Path "$root/$folder") {
        Remove-Item "$root/$folder" -Recurse
    }
    # move items modules and components one level up from the nuget path
    Move-Item "$root/devdeer.Templates.Bicep*/$folder" $root -Force
}
Move-Item "$root/devdeer.Templates.Bicep*/assets/install-modules.ps1" $root -Force
if (!(Test-Path -Path "$root/.gitignore")) {
    Move-Item "$root/devdeer.Templates.Bicep*/assets/.gitignore" $root -Force
}
if (!(Test-Path -Path "$root/bicepSettings.json")) {
    Move-Item "$root/devdeer.Templates.Bicep*/assets/bicepSettings.json" $root -Force
}
# try to remove the nuget installation package
try {
    Remove-Item "$root/devdeer.Templates.Bicep*" -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    # probably we are on the build server herebi
    Write-Host "Could not remove nuget installation folder"
}
