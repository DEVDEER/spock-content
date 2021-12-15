param(
	[string] [Parameter(Mandatory = $true)] $ResourceGroupName,
	[string] [Parameter(Mandatory = $true)] $Name        
)

# retrieve the SSH
$key = Get-AzSshKey  -ResourceGroupName $ResourceGroupName -Name $Name
if ($null -eq $key) {
	# create the SSH
	$key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name
}
# return the public key in outputs
$DeploymentScriptOutputs['publicKey'] = $key.publicKey