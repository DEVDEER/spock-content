# This script assumes that it gets executed in a directory where
# a main.bicep file is present.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2023-03-25

# ensure that we are inside the scripts directory so that we can use relative paths
if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot

if (!(Test-Path "$root/modules")) {
    Write-Host "Installing DEVDEER bicep modules..."
    Invoke-Expression "& $root/install-modules.ps1"
}

$bicepFile = "$root/main.bicep"
$outFolder = "$root/arm-output"
$outFile = "$outFolder/main.json"

if (!(Test-Path -Path $outFolder)) {
    mkdir $outFolder
}

bicep build $bicepFile --outfile $outFile