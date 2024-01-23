$locks = Remove-CafNoDeleteLocksForResourceGroup -ResourceGroupName %RG_NAME%
foreach ($rule in $existintRules) {
    $ruleName = $rule.FirewallRuleName
    if ($ruleName -ne "AllowAllWindowsAzureIps") {
        Remove-AzSqlServerFirewallRule -ServerName %SQL_NAME% -ResourceGroupName %RG_NAME% -FirewallRuleName $ruleName | Out-Null
        if (!$?) {
            Write-Host "Failed to remove firewall rules: $_" -ForegroundColor Red
        }
        Write-Host "Removed rule $ruleName" -ForegroundColor Cyan
    }
    else {
        Write-Host "Ignoring default rule $ruleName" -VerboseOnly
    }
}
Write-HostSuccess "Removed all firewall rules from server '%SQL_NAME%'"
if ($locks) {
    Write-Host "Re-adding no-delete-rules for resource group" -NoNewline
    New-CafNoDeleteLocksForResourceGroup -ResourceGroupName %RG_NAME% -Locks $locks
    Write-Host "Done"
}
else {
    Write-Host "Skipping re-adding of locks because no locks where found prior to the operation." -VerboseOnly
}