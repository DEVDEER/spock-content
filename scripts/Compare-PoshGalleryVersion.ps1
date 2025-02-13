[CmdletBinding()]
param (
    [string]$PsdFile,
    [string]$ModuleId,
    [switch]$AddBeta,
    [string]$DebugSetting = 'Continue'
)

function Get-LocalPsdVersion([string]$PsdFile, [switch]$AddBeta) {
    $version = (Import-PowerShellDataFile $PsdFile).ModuleVersion
    if ($AddBeta.IsPresent -and !$version.EndsWith("-beta")) {
        $version += "-beta"
    }
    return $version
}

function Get-PowerShellGalleryVersion([string]$ModuleId) {
    $latest = (Get-PSResource $ModuleId)[0]
    return $latest.Version.ToString()
}

function Get-VersionValue([string]$Version) {
    $parts = $Version.Split('-')
    $numberParts = $parts[0].Split('.')
    $number = ([Int32]::Parse($numberParts[0]) * 10000) + ([Int32]::Parse($numberParts[1]) * 1000) + ([Int32]::Parse($numberParts[2]) * 10)
    if ($parts.Length -gt 1) {
        # there is a beta-tag
        $number--
    }
    return $number
}

function Compare-SemanticVersions([string]$Version1, [string]$Version2) {
    if ($Version1 -eq $Version2) {
        return 0
    }
    $number1 = Get-VersionValue $Version1
    $number2 = Get-VersionValue $Version2
    return $number1 -eq $number2 ? 0 : $number1 -lt $number2 ? -1 : 1
}

$DebugPreference = $DebugSetting
$local = Get-LocalPsdVersion -PsdFile $PsdFile -AddBeta
$nuget = Get-PowerShellGalleryVersion $ModuleId
$result = Compare-SemanticVersions $local $nuget
if ($result -eq 0) {
    Write-Host "Local version $local is equal to Gallery version $nuget"
}
elseif ($result -eq -1) {
    Write-Host "Local version $local is older than Gallery version $nuget"
}
elseif ($result -eq 1) {
    Write-Host "Local version $local is newer than Gallery version $nuget"
}
else {
    throw "Something went wrong when comparing local $local with Gallery $nuget"
}
return $result