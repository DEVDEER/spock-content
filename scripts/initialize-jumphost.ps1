$logFile = "$PSScriptRoot\install_log.txt"
$ErrorActionPreference = "Continue"
function Log {
    param($message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -FilePath $logFile -Append
}
# Ensure script is running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log "ERROR: This script must be run as Administrator."
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
function Install-WingetPackage {
    param([string]$packageId)
    try {
        winget install --id $packageId --accept-source-agreements --accept-package-agreements -e
        Log "SUCCESS: Installed $packageId"
    } catch {
        Log "FAIL: $packageId - $_"
    }
}
# Ensure PSResourceGet is installed and usable
function Install-PSResourceGet {
    try {
        if (-not (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
            Log "PSResourceGet not found. Installing..."
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
            Install-Module -Name Microsoft.PowerShell.PSResourceGet -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
            Get-InstalledModule
            Import-Module Microsoft.PowerShell.PSResourceGet -Force
            Log "SUCCESS: Installed PSResourceGet"
        } else {
            Import-Module Microsoft.PowerShell.PSResourceGet -Force
            Log "PSResourceGet already available"
        }
        if (-not (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
            throw "Install-PSResource still not found after install. Something went wrong."
        }
    } catch {
        Log "FAIL: Installing PSResourceGet - $_"
    }
}
function Install-PowerShellModule {
    param([string]$moduleName)
    try {
        Install-PSResource -Name $moduleName -Scope CurrentUser -TrustRepository -Reinstall -ErrorAction Stop
        Log "SUCCESS: Installed PowerShell module $moduleName"
    } catch {
        Log "FAIL: PowerShell module $moduleName - $_"
    }
}
Install-PSResourceGet
# PowerShell modules to install
$modules = @(
    "Az.Accounts",
    "Az.Resources",
    "Az.Network",
    "Microsoft.Graph",
    "Devdeer.Caf",
    "Microsoft.WinGet.Client"	
)
foreach ($mod in $modules) {
    Install-PowerShellModule -moduleName $mod
}
# Check if winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Log "ERROR: Winget is not installed. Cannot proceed with tool installs."
} else {
    $wingetPackages = @(
        "Microsoft.VisualStudioCode",
        "Postman.Postman",
        "Git.Git",
        "7zip.7zip",
        "PowerShell.PowerShell",
        "Microsoft.SQLServerManagementStudio",
        "Microsoft.AzureCLI",
        "Google.Chrome",
        "Mozilla.Firefox",
        "Insecure.Nmap",
        "PortSwigger.BurpSuite.Community",
        "Microsoft.WSL"
    )

    foreach ($pkg in $wingetPackages) {
        Install-WingetPackage -packageId $pkg
    }
}
Log "----- DONE -----"
