param(
	[string] [Parameter(Mandatory = $true)] $ResourceGroupName,
	[string] [Parameter(Mandatory = $true)] $Name,
	[string] [Parameter(Mandatory = $true)] $Password
)

# try to retrieve an existing SSH public key from Azure
$key = Get-AzSshKey  -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
if ($null -eq $key) {
	#
	# create the SSH
	$pass = ConvertTo-SecureString $Password -AsPlainText -Force
	ssh-keygen -b 4096 -C AZURE -f generated -N $pass
	$privateKey = Get-Content -Raw ./generated
	if ($privateKey.StartsWith('{')) {
		$converted = $privateKey | ConvertFrom-Json
		$privateKey = $converted.Value
	}
	if ($privateKey.Value) {
		# for some reason Get-Content seems to return a JToken sometimes
		$privateKey = $privateKey.Value
	}
	$publicKey = Get-Content -Raw ./generated.pub
	Remove-Item generated*
	$key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name -PublicKey $publicKey
	$DeploymentScriptOutputs['privateKey'] = $privateKey
}
# return the public key in outputs
$DeploymentScriptOutputs['publicKey'] = $key.publicKey