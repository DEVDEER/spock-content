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
    $SpecificHostUrl,
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
    $SkipResultFile,
    [switch]
    $RemoveRouteVersionPrefixes
)

$ErrorActionPreference = 'Stop'

function Install-DotnetTool() {
    <#
        .SYNOPSIS
        Ensures that the dotnet Swashbuckle CLI is installed locally in this folder.
    #>
    $configPath = "$PWD/.config/dotnet-tools.json"
    if (!(Test-Path $configPath)) {
        Write-Host "Creating dotnet tool manifest..." -NoNewline
        dotnet new tool-manifest
        Write-Host "Done"
    }
    Write-Host "Ensuring Swashbuckle CLI..." -NoNewline
    dotnet tool install Swashbuckle.AspNetCore.Cli | Out-Null
    Write-Host "Done"
}

function Get-ProjectFileName() {
    <#
        .SYNOPSIS
        Retrieves the file name of a *.csproj in the PWD if there is exactly 1.
    #>
    $projectFiles = Get-ChildItem -File -Filter *.csproj $PWD
    $projectFilesCount = ($projectFiles | Measure-Object).Count
    if ($projectFilesCount -ne 1) {
        throw "Found ${$projectFilesCount} project file(s), but can only handle 1."
    }
    return $projectFiles
}

function Get-AssemblyName() {
    param (
        [string]
        $Filename
    )
    <#
        .SYNOPSIS
        Retrieves the name of the assembly in the current directory either by using the
        <AssemblyName/> from the csproj or by falling back to the file name of the csproj.
        .PARAMETER Filename
        Specifies the name of a csproj file in the PWD.
    #>
    $file = [System.IO.FileInfo]::new($Filename)
    $assemblyName = $file.Name
    [xml]$content = Get-Content -Raw $Filename
    $propGroup = $content.Project.PropertyGroup.Count -gt 1 ? $content.Project.PropertyGroup[0] : $content.Project.PropertyGroup
    $csAssemblyName = $propGroup.AssemblyName
    if ($csAssemblyName.Length -gt 0) {
        $assemblyName = $propGroup.AssemblyName
    }
    return $assemblyName.Trim()
}

function Test-ProjectSettings() {
    param (
        [string]
        $Filename
    )
    <#
        .SYNOPSIS
        Ensures that <DocumentationFile /> and/or <GenerateDocumentationFile /> are present in the csproj.
        .PARAMETER Filename
        Specifies the name of a csproj file in the PWD.
        .OUTPUTS
        0 if no element was found, 1 if <DocumentationFile /> was found and 2 if ONLY <GenerateDocumentationFile /> was found.
    #>
    [xml]$content = Get-Content -Raw $Filename
    $propGroup = $content.Project.PropertyGroup.Count -gt 1 ? $content.Project.PropertyGroup[0] : $content.Project.PropertyGroup
    if ($null -ne $propGroup.DocumentationFile) {
        # <DocumentationFile /> is present and set to true
        return 1
    }
    if ($null -ne $propGroup.GenerateDocumentationFile -and $propGroup.GenerateDocumentationFile -eq $true) {
        # <GenerateDocumentationFile /> is present and set to true
        return 2
    }
    return 0
}

function Set-SwaggerSettings() {
    <#
        .SYNOPSIS
        Searches for all appsettings*.json files in the $PWD and sets the option Swagger.Enable to true for all of them.
    #>
    Write-Host "Collecting appsettings files..." -NoNewline
    $settingsFiles = Get-ChildItem appsettings*.json
    Write-Host "Done."
    foreach ($file in $settingsFiles) {
        Write-Host "Ensuring swagger-enablement in '$file'..." -NoNewline
        $json = Get-Content -Raw $file | ConvertFrom-Json
        $enableExists = $json.Swagger | Get-Member -Name Enable
        if ($enableExists) {
            # set existing property to true
            $json.Swagger.Enable = $true
        }
        else {
            # add a new property with value true just to be sure
            $json.Swagger | Add-Member -Name Enable -Value $true -MemberType NoteProperty
        }
        $json | ConvertTo-Json -Depth 20 | Out-File $file
        Write-Host "Done"
    }
}

function Build-Swagger() {
    param (
        [string]
        $ProjectFilename,
        [string]
        $AssemblyName,
        [string]
        $ApiVersion,
        [bool]
        $ModifyProjectFile,
        [string]
        $Output = 'swagger.json'
    )
    <#
        .SYNOPSIS
        Generates a JSON Swagger file at the desired output location.
        .PARAMETER ProjectFilename
        Specifies the name of a csproj file in the PWD.
        .PARAMETER AssemblyName
        The name of the .NET assembly.
        .PARAMETER ApiVersion
        The version key of Swashbuckle to export to the file in this run (e.g. "v1")
        .PARAMETER ModifyProjectFile
        A bool which defines if the csproj needs to be adjusted before export (replacing <DocumentationFile/> tag value).
        .PARAMETER Output
        Optional output file path to use (defaults to 'bin/swagger.json').
    #>
    # This ensures that "dotnet-swagger.xml" is placed as the documentation file in the csproj and
    # then executes the swagger dotnet cli (https://github.com/domaindrivendev/Swashbuckle.AspNetCore#swashbuckleaspnetcorecli).
    # The replacement is needed because the tooling will change the executable assembly to itself and then
    # it fails if the name is not replace beforehand.
    Write-Host "Generating swagger document for version '$ApiVersion'..."
    if ($ModifyProjectFile -eq $true) {
        $tmpFile = ".tmp"
        Copy-Item -Path $ProjectFilename -Destination $tmpFile
        [xml]$content = Get-Content -Raw -Path $ProjectFilename
        $propGroup = $content.Project.PropertyGroup.Count -gt 1 ? $content.Project.PropertyGroup[0] : $content.Project.PropertyGroup
        $propGroup.DocumentationFile = 'bin\$(Configuration)\$(TargetFramework)\dotnet-swagger.xml'
        $content.Save($ProjectFilename)
    }
    Write-Host "Building project..." -NoNewline
    dotnet build -c Release -o bin/swagger $PWD | Out-Null
    Write-Host "Done"
    Write-Host "Generating swagger..." -NoNewline
    dotnet swagger tofile --output $Output "./bin/swagger/$AssemblyName.dll" $ApiVersion | Out-Null
    Write-Host "Done"
    Write-Host "Replacing stage name..." -NoNewline
    $rawContent = Get-Content -Raw $Output
    if ($RemoveRouteVersionPrefixes.IsPresent) {
        $rawContent = $rawContent -Replace "\/api\/v[0-9]", ""
    }
    $json = $rawContent | ConvertFrom-Json
    $json.info.title = $json.info.title.replace('(Production)', "($($env:DOTNET_ENVIRONMENT))")
    $json | ConvertTo-Json -Depth 20 | Out-File $Output
    Write-Host "Done"
    if ($ModifyProjectFile -eq $true) {
        Move-Item $tmpFile $ProjectFilename -Force
    }
    Write-Host "Swagger document created at [$Output]"
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

# arrange variables and switches
$output = $OutputDirectory.Length -gt 0 ? $OutputDirectory : $PWD
# switch to indicate whether to update API Management
$performUpdate = $false
$fullStageName = $TargetStage -eq 'test' ? 'test' : $TargetStage -eq 'prod' ? 'production' : 'integration'
$resultFile = "result.txt"
$technicalProjectName = $ProjectName.ToLowerInvariant()
$prefix = "$technicalProjectName$(($AdditionalName.Length -gt 0) ? '-' + $AdditionalName.ToLowerInvariant() : '')"
if ($SpecificHostUrl.Length -eq 0) {
    # By default the API is running on an Azure App Service
    $azureNamePart = "$CompanyShortKey-$prefix-$TargetStage"
    $webAppName = "api-$azureNamePart"
    $webAppFullRoot = "https://$webAppName.azurewebsites.net"
}
else {
    # The API is running on a different host like Azure Container Apps
    $webAppFullRoot = $SpecificHostUrl
}
$webAppResourceGroup = "rg-$ProjectName-$TargetStage"
$resourceGroup = $ApiManagementResourceGroup.Length -gt 0 ? $ApiManagementResourceGroup : "rg-$technicalProjectName-shared"
$apiMgmtName = $ApiManagementName.Length -gt 0 ? $ApiManagementName : "apim-$CompanyShortKey-$technicalProjectName"
# setting the DOTNET_ENVIRONMENT variable to a valid .NET stage so that later steps can act as if they are running on that stage
$env:DOTNET_ENVIRONMENT = "$($fullStageName.Substring(0,1).ToUpperInvariant())$($fullStageName.Substring(1))"

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
}
else {
    # swagger files need to be generated, prepare required tooling
    Install-DotnetTool
}

Write-Host "Stage is set to '$TargetStage'."
if ($DryRun.IsPresent) {
    "Running in dry-mode -> will not update API management"
}
else {
    Write-Host "Targeted Azure resource are '$apiMgmtName' in '$resourceGroup' and '$webAppFullRoot' in group '$webAppResourceGroup'."
}

Write-Host "Retrieving all Swagger versions from app settings file... "
$settingsFile = "$PWD/appsettings.json"
if (!(Test-Path $settingsFile)) {
    # We don't have an appsettings.json here. In CI this is normal because we should run inside of the project folder. This
    # means that we are currently not in a CI pipeline.
    $settingsFile = "$PWD/appsettings$($AdditionalName.Length -gt 0 ? ".$($AdditionalName.ToLowerInvariant())" : '').json"
}
Write-Host "Reading $settingsFile..."
$settingsContent = Get-Content -Raw $settingsFile
$json = $settingsContent | ConvertFrom-Json -Depth 10
$versions = $json.Swagger.SupportedVersions
$versionsAmount = ($versions | Measure-Object).Count
Write-Host "Done. Found $versionsAmount versions."

if ($versionsAmount -eq 0) {
    Write-Host $settingsContent
    throw "No API versions found in $settingsFile."
}

if (!$DryRun.IsPresent) {
    # prepare the Azure context for accessing API management
    $currentSubscription = (Get-AzContext).Subscription.Id
    if ($ApiManagementSubscriptionId.Length -gt 0 -and $currentSubscription -ne $ApiManagementSubscriptionId) {
        Write-Host "Setting Azure context to subscription $ApiManagementSubscriptionId..." -NoNewline
        Set-AzContext -SubscriptionId $ApiManagementSubscriptionId | Out-Null
        Write-Host "Done"
    }
    Write-Host "Setting API Management context for API management '$resourceGroup/$apiMgmtName'... " -NoNewline
    $ctx = New-AzApiManagementContext -ResourceGroupName $resourceGroup -ServiceName $apiMgmtName
    Write-Host "Done"
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
        $projectFileName = Get-ProjectFileName
        if ($AssemblyName.Length -eq 0) {
            # assembly name was not passed in as parameter -> read it from the project file
            $AssemblyName = Get-AssemblyName -Filename $projectFileName
        }
        Write-Host "Resolved assembly name is [$AssemblyName]."
        $docType = Test-ProjectSettings -FileName $projectFileName
        if ($docType -eq 0) {
            throw "The project does not generate XML documentations. Add <GenerateDocumentationFile/> and/or <DocumentationFile/> tags."
        }
        Write-Host "Project information is set up to generate XML documentation files."
        Set-SwaggerSettings
        Build-Swagger -AssemblyName $AssemblyName -ApiVersion $TargetApiVersion -ProjectFileName $projectFileName -ModifyProjectFile ($docType -eq 1)
        # transform the structure of json file
        TransformJson
        Copy-Item ".\swagger.json" $swaggerFile
        Write-Host "File '$swaggerFile' was generated."
    }
    else {
        Write-Host "Using existing swagger file $($swaggerFile)."
    }

    if ($DryRun.IsPresent) {
        # thats it for this version -> don't actually do anything
        Write-Host "Skipping update operations on API Management because of dry run."
        continue
    }
    Write-Host "Retrieving information for API ID '$apiId' ... " -NoNewline
    try {
        $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
    }
    catch {
        # we should try a different ID because some APIs do not have the version tag in it
        Write-Host "Error"
        if ($SpecificHostUrl.Length -eq 0) {
            $apiId = $azureNamePart
            Write-Host "Retry with new API ID '$apiId'... " -NoNewline
            $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
        }
    }
    if (!$api) {
        throw "Could not retrieve API from APIM context."
    }

    $latestRevision = (Get-AzApiManagementApiRevision -Context $ctx -ApiId $apiId)[0]
    $currentRevision = [int]$latestRevision.ApiRevision
    $currentVersionSetId = $api.ApiVersionSetId.Split("/")[-1]
    $revision = $currentRevision + 1
    $swaggerSpecFile = 'swagger.online.json'
    Write-Host "Done"

    Write-Host "Retrieving current API spec for revision '$currentRevision' in version set '$currentVersionSetId'..." -NoNewline
    Export-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiRevision $currentRevision `
        -SpecificationFormat "OpenApiJson" | Out-File $swaggerSpecFile | Out-Null
    Write-Host "Done"

    Write-Host "Detecting API changes..." -NoNewline
    #TODO Implement version change step
    Move-Item $swaggerFile $swaggerSpecFile -Force
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

    Write-Host "Importing API for into new revision '$revision' version set '$currentVersionSetId' from file '$swaggerSpecFile'... " -NoNewline
    Import-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiVersionSetId $currentVersionSetId `
        -ApiRevision $revision `
        -SpecificationFormat "OpenApi" `
        -SpecificationPath $swaggerSpecFile `
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

    $api = $null

    Write-Host "Handling of API version $targetApiVersion succeeded."
}

$ctx = $null

# delete the result file
if (Test-Path -Path swagger.json) {
    Remove-Item swagger.json
}

# write success in result file
if (!$SkipResultFile.IsPresent) {
    "Success" | Out-File $resultFile
}

Write-Host "🆗"
