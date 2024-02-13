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
    $PrincipalId,
    [string]
    $PrincipalSecret,
    [string]
    $TenantId,
    [string]
    [ValidateSet('Succeeded', 'Failed', 'Waiting')]
    $StatusState,
    [string]
    $StatusDescription = ''
)
# Install and import the Az module
Install-Module Az.Accounts -Force -AllowClobber -Scope CurrentUser
Import-Module Az.Accounts -Global -Force
$baseUrl = "$($CollectionUri)$($ProjectName)/_apis"
# Authenticate with Azure DevOps
$secureStringPwd = $PrincipalSecret | ConvertTo-SecureString -AsPlainText -Force
$pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $PrincipalId, $secureStringPwd
Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $TenantId
# Get the access token
$Token = (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798").Token
$headers = @{ Authorization = "Bearer $Token" }
# Set the suffix
$suffix = "?api-version=7.0"
# Get the repo
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
