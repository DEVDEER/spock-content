[CmdletBinding()]
param (
    [string]
    $ResourceGroup,
    [string]
    $AciName,
    [string]
    $ContainerImageName,
    [string]
    $ContainerImageTagToDeploy,
    [string]
    $AcrName,
    [string]
    $LogAnalyticsKey = '',
    [string]
    $DeploySpName = '',
    [string]
    $DeploySpKeyVaultName = '',
    [string]
    $DeploySpKeyVaultKey = ''
)

function Remove-Block() {
    param (
        [string[]]
        $content,
        [string]
        $blockStart
    )
    $result = @()
    $regexStart = "^(\s*)$blockStart*.$"
    $started = $false
    $indent = -1
    $no = 0
    foreach ($line in $content) {
        $no++
        $append = $false
        if ($line -match $regexStart) {
            $indent = $matches[1].Length
            $started = $true
        }
        else {
            if ($started) {
                if ($line -match "^( *).*") {
                    $currentLineIndent = $matches[1].Length
                    if ($currentLineIndent -le $indent) {
                        $started = $false
                        $append = $true
                    }
                }
            }
            else {
                $append = $true
            }
        }
        if ($append) {
            $result += $line
        }
    }
    $result
}

$ErrorActionPreference = 'Stop'
Write-Host "Version: 1.4"
Write-Host "Updating to image: $($ContainerImageName):$ContainerImageTagToDeploy"
$path = "$PSScriptRoot/aci-config.yaml"
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
$content = Remove-Block -content $content -blockStart "ipAddress:"
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
# Redeploy from YAML — credentials need to be injected separately as they're not exported
if ($DeploySpName.Length -gt 0 -and $DeploySpKeyVaultName.Length -gt 0 -and $DeploySpKeyVaultKey.Length -gt 0) {
    # Deploy with passing registry server data
    $clientId = (az ad sp list --display-name $DeploySpName --query "[0].appId" -o tsv).Trim()
    $password = (az keyvault secret show --vault-name $DeploySpKeyVaultName -n $DeploySpKeyVaultKey --query value -o tsv).Trim()
    az container create `
        -g $ResourceGroup `
        -n $AciName `
        -f $path `
        --registry-login-server $AcrName `
        --registry-username $clientId `
        --registry-password $password `
        -o json
}
else {
    # Deploy without passing registry server data
    az container create -g $ResourceGroup -n $AciName -f $path -o json
}
