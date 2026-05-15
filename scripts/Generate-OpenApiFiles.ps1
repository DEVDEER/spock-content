
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
    $ServerHost = '',
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
if (!($SkipServers.IsPresent) -and $ServerHost.Length -eq 0) {
    throw "If you don't skip server addition you need to specify ServerHost."
}
$ProjectName = $ProjectName.ToLowerInvariant()
$AdditionalName = $AdditionalName.ToLowerInvariant()
$resolvedAdditionalName = $AdditionalName.Length -gt 0 ? ".$AdditionalName" : ''
$resolvedAdditionalPath = $AdditionalName.Length -gt 0 ? "/$AdditionalName" : ''
$files = Get-ChildItem "$BuildOutputDirectory/*.json"
foreach ($file in $files) {
    foreach ($stage in $Stages) {
        $json = Get-Content -Raw $file | ConvertFrom-Json -Depth 20
        $version = $json.info.version
        if (!($SkipServers.IsPresent)) {
            # add server url to OpenAPI
            $host = $ServerHost -replace '%STAGE%',$stage
            $null = $json | Add-Member -MemberType NoteProperty -Name "servers" -Value @(@{ url = "https://$host" })
        }
        $null = $json | ConvertTo-Json -Depth 20 | Set-Content "$OutputDirectory/openapi.$($ProjectName)$($resolvedAdditionalName).$stage.v$version.json"
    }
}
