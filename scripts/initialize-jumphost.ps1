$logFile = "C:\install_log.txt"
$ErrorActionPreference = "Continue"
# Functin to write to log txt file
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
# Install Chocolatey
function Install-Chocolatey {
    try {
        if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
            Log "Chocolatey not found. Installing..."
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            Log "SUCCESS: Installed Chocolatey"
        } else {
            Log "Chocolatey already available"
        }
    } catch {
        Log "FAIL: Installing Chocolatey - $_"
    }
}
# function to install the choco package
function Install-ChocoPackage {
    param([string]$packageId)
    try {
        choco install $packageId -y --no-progress
        Log "SUCCESS: Installed $packageId"
    } catch {
        Log "FAIL: $packageId - $_"
    }
}
# Install PSResourceGet if missing
function Install-PSResourceGet {
    try {
        if (-not (Get-Command Install-PSResource -ErrorAction SilentlyContinue)) {
            Log "PSResourceGet not found. Installing..."
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers -ErrorAction Stop
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
            Install-Module -Name Microsoft.PowerShell.PSResourceGet -Force -AllowClobber -Scope AllUsers -ErrorAction Stop
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
# Function to install powershell modules
function Install-PowerShellModule {
    param([string]$moduleName)
    try {
        Install-PSResource -Name $moduleName -Scope AllUsers -TrustRepository -Reinstall -ErrorAction Stop
        Log "SUCCESS: Installed PowerShell module $moduleName"
    } catch {
        Log "FAIL: PowerShell module $moduleName - $_"
    }
}
# Run setup
Install-Chocolatey
Install-PSResourceGet

# PowerShell modules to install
$modules = @(
    "Az.Accounts",
    "Az.Resources",
    "Az.Network",
    "Microsoft.Graph",
    "Devdeer.Caf"
)
# Install powershell modules
foreach ($mod in $modules) {
    Install-PowerShellModule -moduleName $mod
}
# Choco packages to install (mapped equivalents)
$chocoPackages = @(
    "vscode",
    "postman",
    "git",
    "7zip",
    "powershell-core",
    "sql-server-management-studio",
    "azure-cli",
    "googlechrome",
    "firefox",
    "nmap",
    "burpsuite",
    "wsl"
)
# Install choco packages
foreach ($pkg in $chocoPackages) {
    Install-ChocoPackage -packageId $pkg
}
Log "----- DONE -----"
