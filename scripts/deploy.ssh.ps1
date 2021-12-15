param(
	[string] [Parameter(Mandatory = $true)] $ResourceGroupName,
	[string] [Parameter(Mandatory = $true)] $Name        
)

$key = New-AzSshKey -ResourceGroupName $ResourceGroupName -Name $Name
DeploymentScriptOutputs["publicKey"] = $key.publicKey