function Get-LocalVersion([switch]$AddBeta) {
    $file = './Infrastructure/devdeer.Spock.Infrastructure.csproj'
    [xml]$xml = Get-Content -Raw $file
    $propGroup = $xml.Project.PropertyGroup.Count -gt 1 ? $xml.Project.PropertyGroup[0] : $xml.Project.PropertyGroup
    $version = $propGroup.PackageVersion
    if ($AddBeta.IsPresent -and !$version.EndsWith("-beta")) {
        $version += "-beta"
    }
    return $version
}

function Get-NugetVersion([string]$PackageId) {
    $latest = (Find-Package -Name $PackageId -ProviderName NuGet -AllowPrereleaseVersions -AllVersions)[0]
    return $latest.Version
}

function Get-PowerShellGalleryVersion([string]$ModuleId) {
    $latest = (Get-PSResource $ModuleId)[0]
    return $latest.Version.ToString()
}

function Get-VersionValue([string]$Version) {
    $parts = $Version.Split('-')
    $numberParts = $parts[0].Split('.')
    $number = ([Int32]::Parse($numberParts[0]) * 1000) + ([Int32]::Parse($numberParts[1]) * 100) + [Int32]::Parse($numberParts[2])
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