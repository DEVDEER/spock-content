[CmdletBinding()]
param (
    [string]
    $ResourceGroup,
    [string]
    $AciName,
    [string]
    $DeploySpName,
    [string]
    $DeploySpKeyVaultName,
    [string]
    $DeploySpKeyVaultKey,
    [string]
    $ContainerImageName,
    [string]
    $ContainerImageTagToDeploy,
    [string]
    $AcrName,
    [string]
    $LogAnalyticsKey = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "Version: 1.3"
# Get credentials
$path = "$PSScriptRoot/aci-config.yaml"
$clientId = (az ad sp list --display-name $DeploySpName --query "[0].appId" -o tsv).Trim()
$password = (az keyvault secret show --vault-name $DeploySpKeyVaultName -n $DeploySpKeyVaultKey --query value -o tsv).Trim()
# Export current ACI config to file
az container export --resource-group $ResourceGroup --name $AciName --file $path
if (!(Test-Path $path)) {
    throw "Could not retrieve config from ACI."
}
# Read file
$content = Get-Content $path
# Override the container image tag
$regex = "image: $($ContainerImageName):\S+"
$newImage = "$($ContainerImageName):$ContainerImageTagToDeploy"
$content = $content -replace $regex, "image: $newImage"
# Override API version
#$regex = "apiVersion: \S+"
#$content = $content -replace $regex, "apiVersion: 2025-04-01"
# Remove unsupported settings
$content = $content -replace "provisioningTimeoutInSeconds: \S+", ""
# Add log analytics key after workspaceId
if ($LogAnalyticsKey.Length -gt 0) {
    # there is a workspace id configured
    $regex = '^(\s*)workspaceId:\s*.+'
    $content = foreach ($line in $content) {
        $line
        if ($line -match $regex) {
            $indent = $matches[1]
            "${indent}workspaceKey: $LogAnalyticsKey"
        }
    }
}
# Overwrite the file
$content | Set-Content $path
$content
# Redeploy from YAML — credentials need to be injected separately as they're not exported
az container create --resource-group $ResourceGroup `
    --file $path `
    --registry-login-server $AcrName `
    --registry-username $clientId `
    --registry-password $password `
    -o json
