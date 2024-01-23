$locks = Remove-NoDeleteLocksForResourceGroup -ResourceGroupName %RG_NAME%
foreach ($rule in $existintRules) {
    $ruleName = $rule.FirewallRuleName
    if ($ruleName -ne "AllowAllWindowsAzureIps") {
        Remove-AzSqlServerFirewallRule -ServerName %SQL_NAME% -ResourceGroupName %RG_NAME% -FirewallRuleName $ruleName | Out-Null
        if (!$?) {
            Write-HostError "Failed to remove firewall rules: $_"
        }
        Write-Host "Removed rule $ruleName" -ForegroundColor Cyan
    }
    else {
        Write-HostDebug "Ignoring default rule $ruleName"
    }
}
Write-HostSuccess "Removed all firewall rules from server '%SQL_NAME%'"
if ($locks) {
    Write-HostDebug "Re-adding no-delete-rules for resource group" -NoNewline
    New-NoDeleteLocksForResourceGroup -ResourceGroupName %RG_NAME% -Locks $locks
    Write-HostSuccess "Done"
}
else {
    Write-HostDebug "Skipping re-adding of locks because no locks where found prior to the operation."
}