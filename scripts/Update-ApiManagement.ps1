# Automatically updates revisions and OpenAPI on Azure API management
#
# NOTES
#
# This assumes that the conventions of DEVDEER when it comes to naming and other stuff are the basics of API Management and that an
# Azure App Service is running the API currently. Namely:
#
# - API is named in rg-[PROJECT_NAME]-[STAGE_NAME]
# - The Get-AzContext is set to the correct service principal on the target subscription
# - OpenAPI is configured using the app settings section from project Khan
# - API Ids are build in this way: [COMPANY_SHORT]-[PROJECT_NAME]-[ADDITIONAL_NAME]-[STAGE_SHORT_NAME]
#
# A file result.txt will be generated. If it contains 'Success' then this means that everything went well
# EXIT CODES
#
# 0 success
# Example
#
# ./Update-ApiManagement -TargetStage int -CompanyShortKey KEY -ProjectName PROJECT -AdditionalName core -ApiManagementName apm-test -ApiManagementSubscriptionId 00000-000000-000000-000000 -ApiManagementResourceGroup rg-test
# If you want to perform all steps (swagger and update) in 1 step:

# Copyright DEVDEER GmbH 2026
# Latest update: 2026-05-12

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    [ValidateSet("int", "test", "prod")]
    $TargetStage,
    [Parameter(Mandatory = $true)]
    [string]
    $CompanyShortKey,
    [Parameter(Mandatory = $true)]
    [string]
    $ProjectName,
    [Parameter(Mandatory = $true)]
    [string]
    $AdditionalName,
    [Parameter(Mandatory = $true)]
    [string]
    $ApiManagementName,
    [Parameter(Mandatory = $true)]
    [string]
    $ApiManagementSubscriptionId,
    [Parameter(Mandatory = $true)]
    [string]
    $ApiManagementResourceGroup,
    [Parameter(Mandatory = $false)]
    [string]
    $OpenApiJsonPath = '',
    [Parameter(Mandatory = $false)]
    [string]
    $OutputDirectory,
    [Parameter(Mandatory = $false)]
    $MaximumReleaseAmount = 1,
    [Parameter(Mandatory = $false)]
    [switch]
    $SkipResultFile
)

$ErrorActionPreference = 'Stop'

function CleanupApiManagementReleases() {
    param (
        $ApiManagementContext,
        [string]
        $ApiId
    )
    <#
        .SYNOPSIS
        Removes outdated releases from API management.
        .PARAMETER ApiManagementContext
        The context of the API management.
    #>
    # get delete-lock of resource group
    # This only will work appropriately if there is exactly 1 no delete lock on the resource group
    # holding the API management. If the API Management itself has a lock or more than 1 is inherited
    # then this logic will currently fail.
    $rgName = $ApiManagementContext.ResourceGroupName
    Write-Host "Handling outdated releases on [$rgName.$($ApiManagementContext.ServiceName)]."
    # Wait for other deployment to finish
    while ($true) {
        $rg = Get-AzResourceGroup -Name $rgName
        $tags = $rg.Tags
        $another = ($tags | Where-Object deployment -ne $null).Count -gt 0
        if (!$another) {
            break
        }
        Write-Host "Another deployment currently running. Waiting."
        Start-Sleep 10
    }
    # Setup deploy lease so that no other deployment can interfere
    Write-Host "Setting deploy lease..." -NoNewline
    $rg = Get-AzResourceGroup -Name $rgName
    $tags = $rg.Tags
    $tags += @{ deployment = $ApiId }
    Set-AzResourceGroup -Name $rgName -Tag $tags | Out-Null
    Write-Host "Done"
    # Remove delete locks on resource group
    $locks = Get-AzResourceLock -ResourceGroupName $rgName -LockName nodelete -ErrorAction SilentlyContinue
    if ($locks.Count -gt 1) {
        throw "There are $($lock.Count) delete locks on $rgName but expected was 0 or 1."
    }
    if ($locks.Count -eq 1) {
        # delete existing lock
        Write-Host "Removing current no-delete-lock..." -NoNewline
        $lock = $locks[0]
        $lock | Remove-AzResourceLock -Force | Out-Null
        while (true) {
            # We need to wait for the lock to be removed
            Start-Sleep 10
            $remainingLocks = Get-AzResourceLock -ResourceGroupName $rgName -LockName nodelete -ErrorAction SilentlyContinue
            if ($remainingLocks.Count -eq 0) {
                break
            }
            Write-Host "." -NoNewline
        }
        Write-Host "Done"
    }
    # Now we can delete old releases
    $removedReleases = 0
    $totalReleases = 0
    $oldRevisions = Get-AzApiManagementApi -Context $ApiManagementContext | Where-Object { $_.IsCurrent -eq $false }
    if ($oldRevisions.Count -gt 0) {
        Write-Host "Removing $($oldRevisions.Count) non-current revisions..." -NoNewline
        $oldRevisions | Remove-AzApiManagementApiRevision -Context $ApiManagementContext
        Write-Host "Done"
    }
    $apis = Get-AzApiManagementApi -Context $ApiManagementContext
    foreach ($apiToCheck in $apis) {
        Write-Host "Checking API $($apiToCheck.ApiId) for outdated releases..." -NoNewline
        $currentReleases = Get-AzApiManagementApiRelease -Context $ApiManagementContext -ApiId $apiToCheck.ApiId
        $totalReleases += $currentReleases.Count
        $foundReleases = $currentReleases.Count
        $tmp = 0
        if ($foundReleases -gt $MaximumReleaseAmount) {
            for ($i = $MaximumReleaseAmount; $i -le $foundReleases - 1; $i++) {
                Remove-AzApiManagementApiRelease -ApiId $apiToCheck.ApiId -Context $ApiManagementContext -ReleaseId $currentReleases[$i].ReleaseId
                $tmp++
                $removedReleases++
            }
        }
        Write-Host "$tmp of $foundReleases removed."
    }
    if ($lock) {
        # re-apply deleted lock
        $scope = $lock.ResourceId.Substring(0, $lock.ResourceId.IndexOf("/providers"))
        $lockNotes = $lock.Properties.notes
        if ($null -eq $lockNotes -or $lockNotes.Length -eq 0) {
            $lockNotes = 'Do not delete.'
        }
        New-AzResourceLock -LockName nodelete -Scope $scope -LockNotes $lockNotes -LockLevel $lock.Properties.Level -Force | Out-Null
    }
    Write-Host "Done ($removedReleases of $totalReleases removed)"
    # Remove lease
    Write-Host "Removing deploy lock..." -NoNewline
    $tags = $tags.Remove('deployment')
    if ($null -eq $tags) {
        $tags = @{}
    }
    Set-AzResourceGroup -Name $rgName -Tag $tags | Out-Null
    Write-Host "Done"
}

# arrange variables and switches
$output = $OutputDirectory.Length -gt 0 ? $OutputDirectory : $PWD
$inputDir = $OpenApiJsonPath.Length -gt 0 ? $OpenApiJsonPath : $PWD
$technicalProjectName = $ProjectName.ToLowerInvariant()
$prefix = "$technicalProjectName$(($AdditionalName.Length -gt 0) ? '-' + $AdditionalName.ToLowerInvariant() : '')"
$azureNamePart = "$CompanyShortKey-$prefix-$TargetStage"
$openApiFilePattern = "openapi.$($ProjectName.ToLowerInvariant())$($AdditionalName.Length -gt 0 ? ".$($AdditionalName.ToLowerInvariant())" : '').$($TargetStage).*.json"
Write-Host "Checking path '$($inputDir)'..."
if (!(Test-Path $inputDir)) {
    throw "Directory $inputDir not found"
}
Write-Host "Collecting OpenAPI files:"
$files = Get-ChildItem $inputDir -Filter $openApiFilePattern
if ($files.Count -eq 0) {
    throw "No API versions found at $inputDir with pattern '$openApiFilePattern'."
}
foreach ($file in $files) {
    Write-Host "  $file"
}

Write-Host "Stage is set to '$TargetStage'."

# prepare the Azure context for accessing API management
$currentSubscription = (Get-AzContext).Subscription.Id
if ($ApiManagementSubscriptionId.Length -gt 0 -and $currentSubscription -ne $ApiManagementSubscriptionId) {
    Write-Host "Setting Azure context to subscription $ApiManagementSubscriptionId..." -NoNewline
    Set-AzContext -SubscriptionId $ApiManagementSubscriptionId | Out-Null
    Write-Host "Done"
}
Write-Host "Setting API Management context for API management '$ApiManagementResourceGroup/$ApiManagementName'... "
$ctx = New-AzApiManagementContext -ResourceGroupName $ApiManagementResourceGroup -ServiceName $ApiManagementName
Write-Host "API management context is: [$($ctx.ResourceGroupName).$($ctx.ServiceName)]"
CleanupApiManagementReleases -ApiManagementContext $ctx -ApiId "$prefix-$($TargetStage)"

# We will parse the appSettings.json for every supported API version and update it`s information
# in API Management. We need to do this for "old" APIs too.
foreach ($currentFile in $files) {
    Write-Host "Handling file '$currentFile'."
    $content = Get-Content -Raw $currentFile
    $json = $content | ConvertFrom-Json -Depth 20
    $version = $json.info.version
    if ($version.Length -eq 0) {
        $content
        throw "Could not retrieve API version from '$currentFile'."
    }
    $targetApiVersion = "v$($version.Major)"
    $apiId = "$prefix-$($TargetStage)-v$($version.Major)"
    Write-Host "`n------------------------------------------------------------------------------"
    Write-Host "Starting handling of API version '$targetApiVersion' with assumed id '$apiId'."
    Write-Host "------------------------------------------------------------------------------`n"

    Write-Host "Retrieving information for API ID '$apiId' ... " -NoNewline
    try {
        $api = Get-AzApiManagementApi -Context $ctx -ApiId $apiId
    }
    catch {
        # we should try a different ID because some APIs do not have the version tag in it
        Write-Host "Error"
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

    Write-Host "Importing API for into new revision '$revision' version set '$currentVersionSetId' from file '$currentFile'... " -NoNewline
    Import-AzApiManagementApi `
        -Context $ctx `
        -ApiId $apiId `
        -ApiVersionSetId $currentVersionSetId `
        -ApiRevision $revision `
        -SpecificationFormat "OpenApi" `
        -SpecificationPath $currentFile `
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

# write success in result file
if (!$SkipResultFile.IsPresent) {
    "Success" | Out-File "result.txt"
}

Write-Host "🆗"
