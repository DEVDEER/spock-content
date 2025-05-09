# Is used by the template which generates managed SSH keys.
#
# Copyright DEVDEER GmbH 2024
# Latest update: 2023-03-25

param(
    [string] [Parameter(Mandatory = $true)] $ResourceGroupName,
    [string] [Parameter(Mandatory = $true)] $Name,
    [string] [Parameter(Mandatory = $true)] $KeyVaultPasswordKey,
    [string] [Parameter(Mandatory = $true)] $KeyVaultName,
    [string] [Parameter(Mandatory = $true)] $KeyVaultKey
)

# try to retrieve an existing SSH public key from Azure
$key = Get-AzSshKey  -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
if ($null -eq $key) {
    # create the SSH
    if ($KeyVaultPasswordKey.Length -gt 0) {
        # create private key with passphrase
        $password = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultPasswordKey -AsPlainText
        ssh-keygen -C AZURE -f generated -m PEM -t rsa -b 4096 -N $password
    }
    else {
        # create private key without passphrase
        ssh-keygen -C AZURE -f generated -m PEM -t rsa -b 4096 -N '""' -q
    }
    $privateKey = Get-Content -Raw ./generated
    $publicKey = Get-Content ./generated.pub
    Remove-Item generated*
    $key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name -PublicKey $publicKey
    # store it in the KeyVault
    $secret = ConvertTo-SecureString $privateKey -AsPlainText -Force
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultKey -SecretValue $secret
}
# return the public key in outputs
$DeploymentScriptOutputs['publicKey'] = $key.publicKey
