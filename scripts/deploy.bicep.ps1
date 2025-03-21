# This script assumes that it gets executed in a directory where the
# DEVDEER Bicep Templates are present.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2023-03-25

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("int", "test", "prod")]
    $Stage,
    [Parameter]
    $TenantId,
    [Parameter()]
    $SubscriptionId,
    [switch]
    $WhatIf
)

if ($PSScriptRoot.Contains(' ') -and $PSScriptRoot -ne $PWD) {
    throw "This script needs to be executed from inside its folder because white spaces where detected."
}
$root = $PSScriptRoot.Contains(' ') ? '.' : $PSScriptRoot

if (!$TenantId -or !$SubscriptionId) {
    # try to read tenant and subscription from JSON
    if (!Test-Path "$root/bicepContext.json") {
        throw "You did not supply tenant and/or subscription id. Also there is no bicepSettings.json in the current path. Cannot proceed!"
    }
    $contextJson = Get-Content "$root/bicepContext.json" -Raw | ConvertFrom-Json -Depth 5
    $TenantId = $contextJson.tenantId
    $SubscriptionId = $contextJson.subscriptionId
    if (!$TenantId -or !$SubscriptionId) {
        throw "You did supply bicepSettings.json but tenant and/pr subscription where not defined!"
    }
}

$parameterFile = "$root/parameters/parameters.$Stage.json"
$templateFile = "$root/main.bicep"
$removeTempParameterFile = $false

# Try to find and execute optional pre-deployment script
$preDeployScript = "$root/deploy.bicep.pre.ps1"
if (Test-Path $preDeployScript) {
    Invoke-Expression -Command "& $preDeployScript"
    # The pre-deployment script has left a temp parameter file -> use it
    if (Test-Path "$root/parameters/parameters.temp.json") {
        $parameterFile = "$root/parameters/parameters.temp.json"
        $removeTempParameterFile = $true
    }
}

# ensure that Devdeer.Azure modules is present
if ((Get-Module -all | Select-String -Raw Devdeer.Azure | Measure-Object).Count -eq 0) {
    Write-Host "Installing Devdeer.Azure Powershell..."
    Install-Module Devdeer.Azure -Force
    Import-Module Devdeer.Azure
    Write-Host "Done"
}
else {
    Write-Host "Module Devdeer.Azure Powershell was found."
}

# ensure that DEVDEER BICEP modules are installed
if (!(Test-Path ./modules)) {
    Write-Host "Installing DEVDEER bicep modules..."
    Invoke-Expression -Command "& $root/init.bicep.ps1"
}

if (!$?) {
    if ($removeTempParameterFile) {
        Remove-Item $tempParameterFile
    }
    throw "Some error occured when trying to install BICEP modules."
}

# ensure that the current context is correct
Set-AzdSubscriptionContext -TenantId $TenantId `
    -SubscriptionId $SubscriptionId

if (!$?) {
    if ($removeTempParameterFile) {
        Remove-Item $tempParameterFile
    }
    throw "Could not change subscription context."
}

$name = ((Get-ChildItem $templateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmmss'))
New-AzDeployment `
    -Name $name `
    -Location 'westeurope' `
    -TemplateParameterFile $parameterFile `
    -TemplateFile $templateFile `
    -WhatIf:$WhatIf

if ($removeTempParameterFile) {
    Remove-Item $tempParameterFile
}
