# This script aims to solve the chicken and egg problem by initializing the tenant with
# infrastructure resources that are required for infrastrucutre management by Terraform.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2024-08-24
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $TenantId,
    [Parameter(Mandatory = $true)]
    [string]
    $SubscriptionId,
    [string]
    $ResourceGroupName = "rg-infrastructure-management",
    [string]
    $Location = "westeurope",
    [Parameter(Mandatory = $true)]
    [string]
    $StorageAccountName,
    [string]
    $StorageContainerName = "tfstate",
    [Parameter(Mandatory = $true)]
    [string]
    $KeyVaultName,
    [string]
    $ServicePrincipalName = "sp-terraform-client",
    [string]
    $Role = "Owner",
    [Parameter(Mandatory = $true)]
    [string]
    $ScopeId
)
$ErrorActionPreference = "Stop"
# Set the expiration date for the service principal credentials to 1 year from now
$now = Get-Date
$expiration = $now.AddYears(1)
Write-Host "Initializing Terraform assets..."
Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
# Check if the resource group already exists. if it does skip it and create the storage account
$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($resourceGroup) {
    Write-Host "Resource group '$ResourceGroupName' already exists. Skipping creation" -ForegroundColor Yellow
}
else {
    Write-Host "Creating resource group '$ResourceGroupName' in location '$Location'"
    # create a new resource group
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
    Write-Host "Resource group '$ResourceGroupName' created" -ForegroundColor Green
}
# check if the storage account already exists. if not create one.
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
if ($storageAccount) {
    Write-Host "Storage account '$StorageAccountName' already exists. Skipping creation" -ForegroundColor Yellow
}
else {
    Write-Host "Creating storage account '$StorageAccountName' in resource group '$ResourceGroupName'"
    # create a storage account
    New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -SkuName Standard_LRS -Location $Location
    # Wait for the storage account to be created
    Write-Host "Waiting for the storage account to be created..."
    Start-Sleep -Seconds 10
    Write-Host "Storage account '$StorageAccountName' created" -ForegroundColor Green
    # get the storage account context
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    # create a storage container
    New-AzStorageContainer -Name $StorageContainerName -Context $storageAccount.Context | Out-Null
    Write-Host "Storage container '$StorageContainerName' created"
}
# check if the key vault already exists. if it does skip it and create the service principal
$keyVault = Get-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if ($keyVault) {
    Write-Host "Key vault '$KeyVaultName' already exists. Skipping creation" -ForegroundColor Yellow
}
else {
    Write-Host "Creating key vault '$KeyVaultName' in resource group '$ResourceGroupName'"
    # create a key vault
    $keyVault = New-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $KeyVaultName -Location $Location
    # Wait for the key vault to be created
    Write-Host "Waiting for the key vault to be created..."
    Start-Sleep -Seconds 10
    Write-Host "Key vault '$KeyVaultName' created" -ForegroundColor Green
}
# Check if the service principal already exists. if it does skip it and store the credentials in the key vault
$sp = Get-AzADServicePrincipal -DisplayName $ServicePrincipalName -ErrorAction SilentlyContinue
if ($sp) {
    Write-Host "Service principal '$ServicePrincipalName' already exists. Skipping creation" -ForegroundColor Yellow
    # Check the service principal role assignment
    $roleAssignment = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $ScopeId -ErrorAction SilentlyContinue
    if ($roleAssignment) {
        Write-Host "Service principal '$ServicePrincipalName' already has the role '$Role' at scope '$ScopeId'" -ForegroundColor Yellow
    }
    else {
        # Assign the specified role "Owner" at the specified scope
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $Role -Scope $ScopeId
        Write-Host "Assigned role '$Role' to service principal '$ServicePrincipalName' at scope '$ScopeId'" -ForegroundColor Green
    }
}
else {
    # Create the service principal and assign the specified role "Owner" at the specified scope
    $sp = New-AzADServicePrincipal -DisplayName $ServicePrincipalName -Role $Role -Scope $ScopeId
    Write-Host "Created service principal '$ServicePrincipalName' with id '$($sp.Id)'" -ForegroundColor Green
}
# Store/refresh the service principals password credentials in the key vault
Write-Host "Refreshing service principal credentials and the storage account access key values in key vault: '$keyVaultName'" -ForegroundColor Green
$credential = New-AzADServicePrincipalCredential -ObjectId $sp.Id -EndDate $expiration
$secret = ConvertTo-SecureString -String $credential.SecretText -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $keyVaultName `
    -Name "TerraformClientSpPassword" `
    -SecretValue $secret `
    -Expires $expiration `
    -Tag @{"ServicePrincipalId" = $($sp.Id); "ServicePrincipalName" = $ServicePrincipalName } | Out-Null
Write-Host "Stored service principal credentials in key vault '$keyVaultName' with name '$ServicePrincipalName'"
# store the service principals id in the key vault
$spId = $sp.Id
$credential = ConvertTo-SecureString -String $spId -AsPlainText -Force
$secret = Set-AzKeyVaultSecret -VaultName $keyVault.VaultName `
    -Name "TerraformClientSpId"`
    -SecretValue $credential
Write-Host "Stored service principal id in key vault: $($keyVault.VaultName)"
# get the storage account access key
$storageAccountKey = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -WarningAction SilentlyContinue
# create a storage account key secret
$credential = ConvertTo-SecureString -String $storageAccountKey[0].Value -AsPlainText -Force
$secret = Set-AzKeyVaultSecret -VaultName $keyVault.VaultName `
    -Name "tfStorageAccountAccessKey" `
    -SecretValue $credential
Write-Host "Stored storage account access key in key vault: $($keyVault.VaultName)"
