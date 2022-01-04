param(
	[string] [Parameter(Mandatory = $true)] $ResourceGroupName,
	[string] [Parameter(Mandatory = $true)] $Name,
	[string] [Parameter(Mandatory = $true)] $Password,
	[string] [Parameter(Mandatory = $true)] $KeyVaultName,
	[string] [Parameter(Mandatory = $true)] $KeyVaultKey
)

# try to retrieve an existing SSH public key from Azure
$key = Get-AzSshKey  -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
if ($null -eq $key) {	
	# create the SSH		
	ssh-keygen -C AZURE -f generated -m PEM -t rsa -b 4096 -N $Password
	$privateKey = cat ./generated	
	$publicKey = cat ./generated.pub
	Remove-Item generated*
	$key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name -PublicKey $publicKey
	# store it in the KeyVault
	$secret = ConvertTo-SecureString $privateKey -AsPlainText -Force
	Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultKey -SecretValue $secret	
}
# return the public key in outputs
$DeploymentScriptOutputs['publicKey'] = $key.publicKey
