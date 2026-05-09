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
# Get current container group config
$aci = (az container show --resource-group $ResourceGroup --name $AciName -o json) | ConvertFrom-Json
# Get credentials
$clientId = (az ad sp list --display-name $DeploySpName --query "[0].appId" -o tsv).Trim()
$password = (az keyvault secret show --vault-name $DeploySpKeyVaultName -n $DeploySpKeyVaultKey --query value -o tsv).Trim()
# Extract what you need from existing config
$container = $aci.containers[0]
$newImage = "$($ContainerImageName):$ContainerImageTagToDeploy"
# Redeploy using az container create with existing config exported as YAML
az container export --resource-group $ResourceGroup --name $AciName --file aci-config.yaml
# Patch the YAML
# 1. Override the container image tag
$searchTag = $ContainerImageName #.Replace('.', '\.')
$content = Get-Content aci-config.yaml
$regex = "image: $($searchTag):\S+"
$content = $content -replace $regex, "image: $newImage"
# 2. Remove unsupported settings
$content = $content -replace "provisioningTimeoutInSeconds: \S+", ""
# 4. Add log analytics key after workspaceId
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
# 3. Overwrite the file
$content | Set-Content aci-config.yaml
# Redeploy from YAML — credentials need to be injected separately as they're not exported
az container create --resource-group $ResourceGroup `
    --file aci-config.yaml `
    --registry-login-server $AcrName `
    --registry-username $clientId `
    --registry-password $password `
    -o json
