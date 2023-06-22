# This script uses the Azure DevOps Rest API to set the values of a state in a given PR.
#
# Copyright DEVDEER GmbH 2023
# Latest update: 2023-06-22

param (
    [string]
    $CollectionUri,
    [string]
    $ProjectName,
    [string]
    $PullRequestId,
    [string]
    $Token,
    [string]
    [ValidateSet('Succeeded', 'Failed', 'Waiting')]
    $StatusState,
    [string]
    $StatusDescription = ''
)
$baseUrl = "$($CollectionUri)$($ProjectName)/_apis"
# Authenticate with Azure DevOps
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Token"))
$headers = @{ Authorization = "Basic $base64AuthInfo" }
$suffix = "?api-version=7.0"
# get the repo
$repoUrl = "$baseUrl/git/repositories$suffix"
$repos = Invoke-RestMethod -Uri $repoUrl -Headers $headers -Method Get
$repositoryId = $repos.value.id
# set status to value passed
$statusUrl = "$baseUrl/git/repositories/$repositoryId/pullrequests/$PullRequestId/statuses$suffix"
Write-Host "Calling Azure DevOps REST API on $statusUrl"
$body = @{
    state       = $StatusState
    description = $StatusDescription
    context     = @{
        name  = 'state'
        genre = 'cd'
    }
} | ConvertTo-Json
Invoke-RestMethod -Uri $statusUrl -Headers $headers -Method Post -ContentType "application/json" -Body $body
