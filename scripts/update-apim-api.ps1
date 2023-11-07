# Shortcut for the Start-Sleep which takes seconds only.
#
# NOTES
#
# This assumes that the conventions of DEVDEER when it comes to naming and other stuff are the basics of API Management and that an
# Azure App Service is running the API currently. Namely:
#
# - API Management is running in a rg-[PROJECT_NAME]-shared resource group
# - App Service is named api-[SHORT_KEY]-[PROJECT_NAME]-[ADDITIONAL-NAME]-[STAGE_NAME].azurewebsites.net in rg-[PROJECT_NAME]-[STAGE_NAME]
# - The Get-AzContext is set to the correct service principal on the target subscription
# - Swagger is configured using the app settings section from project Khan
#
# EXIT CODES
#
# 0 success
# 8 could not retrieve swagger from endpoint
# Example
# ./update-apim-api.ps1 -TargetStage prod -CompanyShortKey dd -ProjectName MyDevOpsName -ApiName MyMarketingName -AdditionalName core
# ./update-apim-api.ps1 -TargetStage test -MinStage test -CompanyShortKey dd -ProjectName MyDevOpsName -ApiName MyMarketingName -AdditionalName core
# ./update-apim-api.ps1 -TargetStage prod -CompanyShortKey dd -ProjectName MyDevOpsName -ApiName MyMarketingName -AdditionalName core -IgnoreIpRestrictions
#
# Copyright DEVDEER GmbH 2023
# Latest update: 2023-11-07

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateSet("int", "test", "prod")]
    $TargetStage,
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateSet('int', 'test', 'prod')]
    $MinStage = 'int',
    [Parameter(Mandatory = $true)]
    [string]
    $CompanyShortKey,
    [Parameter(Mandatory = $true)]
    [string]
    $ProjectName,
    [Parameter(Mandatory = $true)]
    [string]
    $ApiName,
    [Parameter(Mandatory = $false)]
    [string]
    $AdditionalName,
    [Parameter(Mandatory = $false)]
    [string]
    $ApiManagementName,
    [Parameter(Mandatory = $false)]
    [string]
    $ApiManagementResourceGroup,
    [Parameter(Mandatory = $false)]
    [string]
    $ApiManagementSubscriptionId,
    [switch]
    $IgnoreIpRestrictions,
    [switch]
    $DryRun
)

function Add-IpRestrictionExcemption($resourceGroup, $appName, $ipAddress) {
    Write-Host "Adding IP restriction rule for web app '$appName' for IP '$ipAddress' ... " -NoNewline
    Add-AzWebAppAccessRestrictionRule `
        -ResourceGroupName $resourceGroup `
        -WebAppName $appName `
        -Name 'AllowPipelineAgent' `
        -Priority 4 `
        -Action Allow `
        -IpAddress $ipAddress
    Write-Host "Done"
}

function Remove-IpRestrictionExcemption($resourceGroup, $appName) {
    Write-Host "Adding IP restriction rule for web app '$appName'... " -NoNewline
    Remove-AzWebAppAccessRestrictionRule `
        -ResourceGroupName $resourceGroup `
        -WebAppName $appName `
        -Name 'AllowPipelineAgent'
    Write-Host "Done"
}

$TargetStage = $TargetStage.toLowerInvariant()
$performUpdate = $false
$apiIdStage = $TargetStage -eq 'test' ? 'test' : $TargetStage -eq 'prod' ? 'production' : 'integration'
$resultFile = "result.txt"
$technicalProjectName = $ProjectName.ToLowerInvariant()
$prefix = "$technicalProjectName$(($AdditionalName.Length -gt 0) ? '-' + $AdditionalName : '')"
$azureNamePart = "$CompanyShortKey-$prefix-$TargetStage"
$webAppName = "api-$azureNamePart"
$webAppFullRoot = "https://$webAppName.azurewebsites.net"
$ipAddress = (Invoke-WebRequest -uri "http://api.ipify.org?format=text").Content
$webAppResourceGroup = "rg-$ProjectName-$($TargetStage -eq 'prod' ? 'production' : $TargetStage)"
$handleIpExcemption = !($DryRun.IsPresent) -and !(IgnoreIpRestrictions.IsPresent) -and $TargetStage -ne $MinStage
$resourceGroup = $ApiManagementResourceGroup.Length -gt 0 ? $ApiManagementResourceGroup : "rg-$technicalProjectName-shared"
$apiMgmtName = $ApiManagementName.Length -gt 0 ? $ApiManagementName : "apim-$CompanyShortKey-$technicalProjectName"

Write-Host "Stage is set to '$TargetStage'."
Write-Host "Current IP address is '$ipAddress'."
Write-Host "Targeted Azure resource are $apiMgmtName in $resourceGroup and $webAppFullRoot in group $webAppResourceGroup."

Write-Host "Retrieving all Swagger versions from app settings file ... " -NoNewline
$content = Get-Content appsettings.json
$json = $content | ConvertFrom-Json
Write-Host "Done"

# We will parse the appSettings.json for every supported API version and update it`s information
# in API Management. We need to do this for "old" APIs too.
foreach ($version in $json.Swagger.SupportedVersions) {
    $targetApiVersion = "v$($version.Major)"
    Write-Host "Starting handling of API version $targetApiVersion."

    # delete the result file
    if (Test-Path -Path $resultFile) {
        Remove-Item $resultFile
    }

    # add restriction if not on min
    if ($handleIpExcemption) {
        Add-IpRestrictionExcemption($webAppResourceGroup, $webAppName, $ipAddress)
    }

    # wait for some time to enable the restriction to take effect
    Start-Sleep -Seconds 5

    # download the swagger json from the stage
    try {
        $url = "$webAppFullRoot/swagger/$targetApiVersion/swagger.json"
        Write-Host "Retrieving Swagger from '$TargetStage' stage for API version '$targetApiVersion' ($url) ... " -NoNewline
        Invoke-WebRequest -Uri $url -Outfile swagger.json
        Write-Host "Done"
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        $FailedItem = $_.Exception.ItemName
        Write-Host "Error: $ErrorMessage on $FailedItem for url $url"
        exit 8
    }
    finally {
        if ($handleIpExcemption) {
            Remove-IpRestrictionExcemption($webAppResourceGroup, $webAppName)
        }
    }

    Write-Host "Replacing Swagger information for target stage '$TargetStage' ... " -NoNewline
    $content = Get-Content -Raw swagger.json
    $targetSwaggerJson = $content | ConvertFrom-Json -Depth 100
    $targetSwaggerJson.info.title = $targetSwaggerJson.info.title.Replace($TargetStage, $apiIdStage)
    $targetSwaggerJson.info.title = $targetSwaggerJson.info.title.Replace($ProjectName, $ApiName)
    $content = $targetSwaggerJson | ConvertTo-Json -Depth 100
    $content = $content.Replace("api/$targetApiVersion/", "")
    Set-Content swagger.json $content
    Write-Host "Done"

    # This is not fully understood. We are converting the complete swagger.json to a set
    # of nested POSH hashtables because ConvertFrom-Json is otherwise unable to understand
    # the dictionary structure of the JSON. This is supposed to do the following:
    # 1. Copy the value from the attribute "summary" to a new attribute "description"
    # 2. Set the value of the attribute "summary" to the same as in the attribute "operationId"
    # We do this so that the resulting APIM documentation will display the operation ids as
    # the name of the methods and not the default summaries from .NET comments which should be
    # the descriptions instead.
    $json = Get-Content ".\swagger.json" -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
    $copy = Get-Content ".\swagger.json" -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
    foreach ($endpointPath in $json.paths.Keys) {
        foreach ($methods in $json.paths[$endpointPath]) {
            foreach ($method in $methods) {
                $result = @{}
                foreach ($methodName in $method.Keys) {
                    $val = $method[$methodName]
                    $content = $val | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
                    $content | Add-Member -Name description -Value $content.summary -Type NoteProperty -Force
                    $content.summary = $content.operationId
                    $res = $content
                    $result.Add($methodName, $res)
                }
            }
            $copy.paths[$endpointPath] = $result
        }
    }
    $copy | ConvertTo-Json -Depth 20 | Set-Content ".\swagger.json"

    if ($DryRun.IsPresent) {
        Copy-Item ".\swagger.json" ".\swagger.$TargetStage.$targetApiVersion.json"
        Write-Host "File .\swagger.$TargetStage.$targetApiVersion.json was generated."
        continue
    }

    Write-Host "Setting API Management context for API ID '$apiId' ... " -NoNewline
    $ctx = New-AzApiManagementContext -ResourceGroupName $resourceGroup -ServiceName $apiMgmtName
    Write-Host "Done"

    Write-Host "Retrieving information for API ID '$apiId' ... " -NoNewline
    try {
        $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
    }
    catch {
        # we should try a different ID because some APIs do not have the version tag in it
        $apiId = $azureNamePart
        Write-Host "Retry with new API ID '$apiId' ... " -NoNewline
        $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
    }

    if (!$api) {
        throw "Could not retrieve API from APIM context."
    }

    $latestRevision = (Get-AzApiManagementApiRevision -Context $ctx -ApiId $apiId)[0]
    $currentRevision = [int]$latestRevision.ApiRevision
    $currentVersionSetId = $api.ApiVersionSetId.Split("/")[-1]
    $revision = $currentRevision + 1
    Write-Host "Done"

    Write-Host "Retrieving current API spec for revision '$currentRevision' in version set '$currentVersionSetId'..." -NoNewline
    Export-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $currentRevision `
        -SpecificationFormat "OpenApiJson" | Out-File swagger.online.json
    Write-Host "Done"

    Write-Host "Detecting API changes..."
    #TODO Implement version change step
    $performUpdate = $true
    Write-Host "Done"

    if (!$performUpdate) {
        Write-Host "Skipping update of API Management."
        return;
    }

    Write-Host "Creating new revision '$revision' ... " -NoNewline
    New-AzApiManagementApiRevision `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $revision
    Write-Host "Done"

    Write-Host "Making revision '$revision' default ... " -NoNewline
    New-AzApiManagementApiRelease `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $revision
    Write-Host "Done"

    Write-Host "Importing API for '$revision' in version set '$currentVersionSetId'... " -NoNewline
    Import-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiVersionSetId $currentVersionSetId `
        -ApiRevision $revision `
        -SpecificationFormat "OpenApi" `
        -SpecificationPath swagger.json `
        -Path $api.Path
    Write-Host "Done"

    $backendUrl = "$webAppFullRoot/api/$targetApiVersion"
    Write-Host "Resetting backend API url to '$backendUrl' default ... " -NoNewline
    Set-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ServiceUrl $backendUrl
    Write-Host "Done"

    # prepare for next run
    $ctx = $null
    $api = $null

    Write-Host "Handling of API version $targetApiVersion succeeded."
}

# write success in result file
"Success" | Out-File $resultFile

Write-Host "🆗"

