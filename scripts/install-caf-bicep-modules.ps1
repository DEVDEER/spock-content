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

if ($Prerelease.IsPresent) {
    Install-Package -Name "devdeer.Templates.Bicep"  `
        -Scope CurrentUser `
        -ProviderName nuget `
        -Destination $PSScriptRoot `
        -Force `
        -AllowPrereleaseVersions
} else {
    Install-Package -Name "devdeer.Templates.Bicep"  `
        -Scope CurrentUser `
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