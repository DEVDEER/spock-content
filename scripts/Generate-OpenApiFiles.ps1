
# Automatically searches for files in the openapi output directory and generates OpenAPI JSON files for
# each detected fi
#
# NOTES
#
# Example
#
# Copyright DEVDEER GmbH 2026
# Latest update: 2026-05-12

[CmdletBinding()]
param (
    [string]
    $ProjectName,
    [string]
    $AdditionalName = '',
    [string]
    $ApiManagementHostname = '',
    [string]
    $BuildOutputDirectory = 'openapi',
    [string]
    $OutputDirectory = $null,
    [array]
    $Stages = @( 'int', 'test', 'prod'),
    [switch]
    $SkipServers
)
$ErrorActionPreference = 'Stop'
if (!($SkipServers.IsPresent) -and $ApiManagementHostname.Length -eq 0) {
    throw "If you don't skip server addition you need to specify ApiManagementHostname."
}
$ProjectName = $ProjectName.ToLowerInvariant()
$AdditionalName = $AdditionalName.ToLowerInvariant()
$resolvedAdditionalName = $AdditionalName.Length -gt 0 ? ".$AdditionalName" : ''
$resolvedAdditionalPath = $AdditionalName.Length -gt 0 ? "/$AdditionalName" : ''
$files = Get-ChildItem "$BuildOutputDirectory/*.json"
foreach ($file in $files) {
    $json = Get-Content -Raw $file | ConvertFrom-Json -Depth 20
    $json = $json | ConvertTo-Json -Depth 20
    $version = $json.info.version
    if (!($SkipServers.IsPresent)) {
        # add server url to OpenAPI
        $null = $json | Add-Member -MemberType NoteProperty -Name "servers" -Value @(@{ url = "https://$ApiManagementHostname/$ProjectName/$($stage)$($resolvedAdditionalPath)/v$version" })
    }
    foreach ($stage in $Stages) {
        $null = $json | Set-Content "$OutputDirectory/openapi.$($ProjectName)$($resolvedAdditionalName).$stage.v$version.json"
    }
}