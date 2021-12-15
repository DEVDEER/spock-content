param(
	[string] [Parameter(Mandatory = $true)] $ResourceGroupName,
	[string] [Parameter(Mandatory = $true)] $Name,
	[string] [Parameter(Mandatory = $true)] $Password
)

# retrieve the SSH
$key = Get-AzSshKey  -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
if ($null -eq $key) {
	# create the SSH	
	ssh-keygen -b 4096 -C AZURE -f generated -N $Password
	$privateKey = Get-Content -Raw ./generated
	$publicKey = Get-Content -Raw ./generated.pub
	Remove-Item generated*
	$key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name -PublicKey $publicKey
	$DeploymentScriptOutputs['privateKey'] = $privateKey
}
# return the public key in outputs
$DeploymentScriptOutputs['publicKey'] = $key.publicKey