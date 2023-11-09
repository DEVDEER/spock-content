# Automatically updates revisions and OpenAPI on Azure API management
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
# - API Ids are build in this way: [COMPANY_SHORT]-[PROJECT_NAME]-[ADDITIONAL_NAME]-[STAGE_SHORT_NAME]
#
# A file result.txt will be generated. If it contains 'Success' then this means that everything went well
# EXIT CODES
#
# 0 success
# 8 could not retrieve swagger from endpoint
# Example
#
# If you want to perform all steps (swagger and update) in 1 step:
# ./update-apim-api.ps1 -TargetStage test -MinStage test -CompanyShortKey dd -ProjectName TECHNICAL_NAME -ApiName MARKETING_NAME -AdditionalName read -AssemblyName NAME_OF_DLL_WITHOUT_DLL -OutputDirectory d:\temp -SkipResultFile -DryRun
#
# If you want to create a file in the output dir with "swagger.PROJECT.ADDITIONAL_NAME.STAGE.VERSION.json"pattern (USE THIS IN CI PIPELINES)
# ./update-apim-api.ps1 -TargetStage test -MinStage test -CompanyShortKey dd -ProjectName TECHNICAL_NAME -ApiName MARKETING_NAME -AdditionalName read -AssemblyName NAME_OF_DLL_WITHOUT_DLL -OutputDirectory d:\temp -SkipResultFile
#
# If you already have a file in the PWD with "swagger.PROJECT.ADDITIONAL_NAME.STAGE.VERSION.json" pattern (USE THIS IN CD PIPELINES)
# ./update-apim-api.ps1 -TargetStage test -MinStage test -CompanyShortKey dd -ProjectName TECHNICAL_NAME -ApiName MARKETING_NAME -AdditionalName read -ApiManagementResourceGroup rg-api -ApiManagementName apim-dd-shared -UseExistingSwaggerFiles
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
    [Parameter(Mandatory = $false)]
    [string]
    $AssemblyName,
    [Parameter(Mandatory = $false)]
    [string]
    $OutputDirectory,
    [Switch]
    $UseExistingSwaggerFiles,
    [Parameter(Mandatory = $false)]
    [switch]
    $DryRun,
    [Parameter(Mandatory = $false)]
    [switch]
    $SkipResultFile
)

$ErrorActionPreference = 'Stop'

function CheckDotnetTool() {
    # This ensures that the dotnet swashbuckle CLI is installed on the computer.
    if (!(Test-Path ~\.dotnet\tools\swagger.exe)) {
        Write-Host "Swashbuckle global tool not found. Installing..." -NoNewline
        dotnet tool install -g Swashbuckle.AspNetCore.Cli
        Write-Host "Done"
    } else {
        Write-Host "Swashbuckle global tool found."
    }
}

function GenerateSwagger() {
    param (
        $ApiVersion,
        $AssemblyName
    )
    # This ensures that "dotnet-swagger.xml" is placed as the documentation file in the csproj and
    # then executes the swagger dotnet cli (https://github.com/domaindrivendev/Swashbuckle.AspNetCore#swashbuckleaspnetcorecli).
    # The replacement is needed because the tooling will change the executable assembly to itself and then
    # it fails if the name is not replace beforehand.
    Write-Host "Generating swagger document for version '$ApiVersion'..."
    $projFiles = Get-ChildItem -File *.csproj
    $projFile = $projFiles[0]
    $tmpFile = "$projFile.tmp"
    Copy-Item $projFile $tmpFile
    $origContent = Get-Content -Raw $projFile
    $origContent -match '<DocumentationFile>(.*).xml' | Out-Null
    $match = $Matches[1]
    $parts = $match.Split("\")
    $file = $parts[-1]
    $match = $match.Replace($file, "dotnet-swagger")
    $content = $origContent.Replace($Matches[1], $match)
    $content | Out-File $projFile

    Write-Host "Building project..." -NoNewline
    dotnet build -c Release -o build $PWD | Out-Null
    Write-Host "Done"

    Write-Host "Generating swagger..." -NoNewline
    swagger tofile --output swagger.json "./build/$assemblyName.dll" $targetApiVersion | Out-Null
    Write-Host "Done"
    Move-Item $tmpFile $projFile -Force
    Write-Host "Swagger document created"
}

function SwapSwaggerMetadata() {
    param (
        $Stage,
        $FullStageName,
        $ProjectName,
        $ApiName,
        $ApiVersion
    )
    Write-Host "Replacing Swagger information for target stage '$Stage'... " -NoNewline
    $content = Get-Content -Raw swagger.json
    $targetSwaggerJson = $content | ConvertFrom-Json -Depth 100
    $targetSwaggerJson.info.title = $targetSwaggerJson.info.title.Replace($Stage, $FullStageName)
    $targetSwaggerJson.info.title = $targetSwaggerJson.info.title.Replace($ProjectName, $ApiName)
    $content = $targetSwaggerJson | ConvertTo-Json -Depth 100
    $content = $content.Replace("api/$ApiVersion/", "")
    Set-Content swagger.json $content
    Write-Host "Done"
}

function TransformJson() {
    # This is not fully understood. We are converting the complete swagger.json to a set
    # of nested POSH hashtables because ConvertFrom-Json is otherwise unable to understand
    # the dictionary structure of the JSON. This is supposed to do the following:
    # 1. Copy the value from the attribute "summary" to a new attribute "description"
    # 2. Set the value of the attribute "summary" to the same as in the attribute "operationId"
    # We do this so that the resulting APIM documentation will display the operation ids as
    # the name of the methods and not the default summaries from .NET comments which should be
    # the descriptions instead.
    $json = Get-Content swagger.json -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
    $copy = Get-Content swagger.json -Raw | ConvertFrom-Json -Depth 20 -AsHashtable
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
    $copy | ConvertTo-Json -Depth 20 | Set-Content swagger.json
}

$output = $OutputDirectory.Length -gt 0 ? $OutputDirectory : $PWD
$TargetStage = $TargetStage.toLowerInvariant()
$performUpdate = $false
$fullStageName = $TargetStage -eq 'test' ? 'test' : $TargetStage -eq 'prod' ? 'production' : 'integration'
$resultFile = "result.txt"
$technicalProjectName = $ProjectName.ToLowerInvariant()
$prefix = "$technicalProjectName$(($AdditionalName.Length -gt 0) ? '-' + $AdditionalName.ToLowerInvariant() : '')"
$azureNamePart = "$CompanyShortKey-$prefix-$TargetStage"
$webAppName = "api-$azureNamePart"
$webAppFullRoot = "https://$webAppName.azurewebsites.net"
$webAppResourceGroup = "rg-$ProjectName-$($TargetStage -eq 'prod' ? 'production' : $TargetStage)"
$resourceGroup = $ApiManagementResourceGroup.Length -gt 0 ? $ApiManagementResourceGroup : "rg-$technicalProjectName-shared"
$apiMgmtName = $ApiManagementName.Length -gt 0 ? $ApiManagementName : "apim-$CompanyShortKey-$technicalProjectName"

$swaggerFilePattern = "swagger.$($ProjectName.ToLowerInvariant())$($AdditionalName.Length -gt 0 ? ".$($AdditionalName.ToLowerInvariant())" : '').$($TargetStage).*.json"
if ($UseExistingSwaggerFiles.IsPresent) {
    # caller has somehow ensured that swagger*.json files in the correct pattern are present at the PWD
    Write-Host "Caller wants to use existing swagger files. Checking path '$($PWD)'..."
    if (!(Test-Path -Filter $swaggerFilePattern $PWD)) {
        throw "No files with pattern '$swaggerFilePattern' where found under $PWD"
    }
    Write-Host "Using existing swagger files:"
    $files = Get-ChildItem -File -Filter $swaggerFilePattern $PWD
    foreach ($file in $files) {
        Write-Host "  $file"
    }

} else {
    # caller does not provide swagger json files
    if ($AssemblyName.Length -eq 0) {
        throw "You need to define AssemblyName if no UseExistingSwaggerFiles is no set!"
    }
}

if (!$UseExistingSwaggerFiles.IsPresent) {
    CheckDotnetTool
}

Write-Host "Stage is set to '$TargetStage'."
if ($DryRun.IsPresent) {
    "Running in dry-mode -> will not update API management"
} else {
    Write-Host "Targeted Azure resource are '$apiMgmtName' in '$resourceGroup' and '$webAppFullRoot' in group '$webAppResourceGroup'."
}

Write-Host "Retrieving all Swagger versions from app settings file ... " -NoNewline
$settingsFile = "$PWD/appsettings.json"
if (!(Test-Path $settingsFile)) {
    # We don't have an appsettings.json here. In CI this is normal because we should run inside of the project folder. This
    # means that we are currently not in a CI pipeline.
    $settingsFile = "$PWD/appsettings$($AdditionalName.Length -gt 0 ? ".$($AdditionalName.ToLowerInvariant())" : '').json"
}
Write-Host "Reading $settingsFile..."
$content = Get-Content -Raw $settingsFile
$json = $content | ConvertFrom-Json -Depth 10
$versions = $json.Swagger.SupportedVersions
$versionsAmount = ($versions | Measure-Object).Count
Write-Host "Done. Found $versionsAmount versions."

if ($versionsAmount -eq 0) {
    Write-Host $content
    throw "No API versions found in $settingsFile."
}

if (!$DryRun.IsPresent) {
    $currentSubscription = (Get-AzContext).Subscription.Id
    $switchSub = $false
    if ($ApiManagementSubscriptionId.Length -gt 0 -and $currentSubscription -ne $ApiManagementSubscriptionId) {
        Write-Host "Setting Azure context to subscription $ApiManagementSubscriptionId..." -NoNewline
        Set-AzContext -SubscriptionId $ApiManagementSubscriptionId
        Write-Host "Done"
        $switchSub = $true
    }
    Write-Host "Setting API Management context for API ID '$apiId' on '$resourceGroup/$apiMgmtName'... " -NoNewline
    $ctx = New-AzApiManagementContext -ResourceGroupName $resourceGroup -ServiceName $apiMgmtName
    Write-Host "Done"
    if ($switchSub) {
        Write-Host "Setting Azure context to subscription $currentSubscription..." -NoNewline
        Set-AzContext -SubscriptionId $currentSubscription
        Write-Host "Done"
    }
}

# We will parse the appSettings.json for every supported API version and update it`s information
# in API Management. We need to do this for "old" APIs too.
foreach ($version in $versions) {
    $targetApiVersion = "v$($version.Major)"
    $apiId = "$prefix-$($TargetStage)-v$($version.Major)"
    $swaggerFile = "$output/$($swaggerFilePattern.Replace("*", $targetApiVersion))"

    Write-Host "`n------------------------------------------------------------------------------"
    Write-Host "Starting handling of API version '$targetApiVersion' with assumed id '$apiId'."
    Write-Host "------------------------------------------------------------------------------`n"

    if (!$UseExistingSwaggerFiles.IsPresent) {
        # delete the result file
        if (Test-Path -Path $resultFile) {
            Remove-Item $resultFile
        }

        # generate swagger json document
        GenerateSwagger -ApiVersion $TargetApiVersion -AssemblyName $AssemblyName
        # do replacements
        SwapSwaggerMetadata -Stage $TargetStage -FullStageName $fullStageName -ProjectName $ProjectName -ApiName $ApiName -ApiVersion $targetApiVersion
        # transform the structure of json file
        TransformJson

        Copy-Item ".\swagger.json" $swaggerFile
        Write-Host "File '$swaggerFile' was generated."
    } else {
        Write-Host "Using swagger file $($swaggerFile)."
    }

    if ($DryRun.IsPresent) {
        # thats it for this version -> don't actually do anything
        Write-Host "Skipping because of dry run."
        continue
    }

    Write-Host "Retrieving information for API ID '$apiId' ... " -NoNewline
    try {
        $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
    }
    catch {
        # we should try a different ID because some APIs do not have the version tag in it
        $apiId = $azureNamePart
        Write-Host "Retry with new API ID '$apiId'... " -NoNewline
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
        -SpecificationFormat "OpenApiJson" | Out-File swagger.online.json | Out-Null
    Write-Host "Done"

    Write-Host "Detecting API changes..." -NoNewline
    #TODO Implement version change step
    $performUpdate = $true
    Write-Host "Done"

    if (!$performUpdate) {
        Write-Host "Skipping update of API Management."
        return;
    }

    Write-Host "Creating new revision '$revision' for version '$targetApiVersion' ... " -NoNewline
    New-AzApiManagementApiRevision `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $revision | Out-Null
    Write-Host "Done"

    Write-Host "Making revision '$revision' default... " -NoNewline
    New-AzApiManagementApiRelease `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $revision | Out-Null
    Write-Host "Done"

    Write-Host "Importing API for '$revision' into version set '$currentVersionSetId'... " -NoNewline
    Import-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiVersionSetId $currentVersionSetId `
        -ApiRevision $revision `
        -SpecificationFormat "OpenApi" `
        -SpecificationPath $swaggerFile `
        -Path $api.Path | Out-Null
    Write-Host "Done"

    $backendUrl = "$webAppFullRoot/api/$targetApiVersion"
    Write-Host "Resetting backend API url to '$backendUrl' default... " -NoNewline
    Set-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ServiceUrl $backendUrl | Out-Null
    Write-Host "Done"

    # prepare for next run
    $ctx = $null
    $api = $null

    Write-Host "Handling of API version $targetApiVersion succeeded."
}

# delete the result file
if (Test-Path -Path swagger.json) {
    Remove-Item swagger.json
}

# write success in result file
if (!$SkipResultFile.IsPresent) {
    "Success" | Out-File $resultFile
}

Write-Host "🆗"

