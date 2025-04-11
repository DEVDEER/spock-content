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

$provider = Get-PackageSource -Name nuget.org
if ($null -eq $provider) {
    Register-PackageSource -Name nuget.org -Location https://www.nuget.org/api/v3 -ProviderName nuget.org
}
if ($Prerelease.IsPresent) {
    $version = (Find-Package -Filter devdeer -ProviderName nuget -AllowPrereleaseVersions | Where { $_.Name -eq 'devdeer.Templates.Bicep' }).Version
    Install-Package -Scope CurrentUser `
        -Name "devdeer.Templates.Bicep" `
        -RequiredVersion $version `
        -AllowPrereleaseVersions `
        -Source nuget.org `
        -ProviderName nuget `
        -Destination $PSScriptRoot `
        -Force
} else {
    $version = (Find-Package -Filter devdeer -ProviderName nuget | Where { $_.Name -eq 'devdeer.Templates.Bicep' }).Version
    Install-Package -Scope CurrentUser `
        -Name "devdeer.Templates.Bicep" `
        -RequiredVersion $version `
        -Source nuget.org `
        -ProviderName nuget `
        -Destination $PSScriptRoot `
        -Force
}


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
if (!(Test-Path -Path "$root/.gitgnore")) {
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
