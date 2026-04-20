# This script can be used to redeploy an existing Azure Container Instance (ACI)
# ---------------------------
# ACI redeployments on existing resources is the same as restarting the App.
#
# This script uses Azure REST API to communicate with the ACI.
# Copyright DEVDEER GmbH 2026
# Latest update: 2026-04-20

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]
    $InstanceName,
    [Parameter(Mandatory = $true)]
    [string]
    $DeploySpName,
    [Parameter(Mandatory = $true)]
    [string]
    $DeploySpSecretKeyVaultName,
    [string]
    $TagVersion = '',
    [switch]
    $DontUseCaf
)

if ($DontUseCaf.IsPresent) {
    $ctx = Use-CafContext
    $subscriptionId = $ctx.subscriptionId
}
else {
    $ctx = Get-AzContext
    $subscriptionId = $ctx.Subscription.Id
}
$token = (Get-AzAccessToken).Token | ConvertFrom-SecureString -AsPlainText
$uri = "https://management.azure.com/subscriptions/$($subscriptionId)/resourceGroups/$($ResourceGroup)/providers/Microsoft.ContainerInstance/containerGroups/$($InstanceName)?api-version=2023-05-01"
$definition = Invoke-RestMethod `
    -Uri $uri  `
    -Headers @{ Authorization = "Bearer $token" } `
    -Method Get
$containerDefinition = $definition.properties.containers
$region = $definition.location
$image = $containerDefinition.properties.image -split ":"
$imageName = $image[0]
$subnetId = $definition.properties.subnetIds[0].id
$resources = $definition.properties.containers.properties.resources
$cpu = $resources.requests.cpu
$memory = $resources.requests.memoryInGB
$os = $definition.properties.osType
$restartPolicy = $definition.properties.restartPolicy
if ($TagVersion.Length -eq 0) {
    $TagVersion = $image[-1]
}
$resolvedImage = "$($imageName):$TagVersion"
$registryServer = ($resolvedImage -split "/")[0]
$spId = (Get-AzAdServicePrincipal -DisplayName $DeploySpName).ServicePrincipalName[0]
$spPass = Get-AzKeyVaultSecret -VaultName $DeploySpSecretKeyVaultName -Name $DeploySpName -AsPlainText
$body = @{
    location   = $region
    properties = @{
        osType                   = $os
        restartPolicy            = $restartPolicy
        imageRegistryCredentials = @(
            @{
                server   = $registryServer
                username = $spId
                password = $spPass
            }
        )
        subnetIds                = @(
            @{ id = $subnetId }
        )
        containers               = @(
            @{
                name       = $InstanceName
                properties = @{
                    image     = $resolvedImage
                    resources = @{
                        requests = @{
                            cpu        = [double]$cpu
                            memoryInGB = [double]$memory
                        }
                    }
                }
            }
        )
    }
} | ConvertTo-Json -Depth 10
$exitCode = 0
$message = ''
try {
    $result = Invoke-WebRequest `
        -Uri     $uri `
        -Method  Put `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body    $body
    $exitCode = $result.StatusCode -eq 201 ? 0 : 1
    $message = $result.StatusCode -eq 409 ? "ACI is still transitioning." : "Unknown error $($result.StatusCode)"
}
catch {
    $exitCode = $Error[0].Exception.Response.StatusCode -eq 409 ? 1 : 2
    $message = $Error[0].Exception.Response.StatusCode -eq 409 ? "ACI is still transitioning." : "Unknown error $($Error[0].Exception.Response.StatusCode)"
    $exitCode = 2
}
if ($exitCode -ne 0) {
    Write-Host "Error: $message"
}
exit $exitCode