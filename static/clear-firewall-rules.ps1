$locks = Remove-CafLocks -ResourceGroupName %RG_NAME%
Write-Host "NoDelete locks removed from resource group."
$existintRules = Get-AzSqlServerFirewallRule -ServerName %SQL_NAME% -ResourceGroupName %RG_NAME%
$count = 0
foreach ($rule in $existintRules) {
    $ruleName = $rule.FirewallRuleName
    if ($ruleName -ne "AllowAllWindowsAzureIps") {
        Remove-AzSqlServerFirewallRule -ServerName %SQL_NAME% -ResourceGroupName %RG_NAME% -FirewallRuleName $ruleName | Out-Null
        if (!$?) {
            Write-Host "Failed to remove firewall rules: $_" -ForegroundColor Red
        } else {
            $count++
        }
        Write-Host "Removed rule $ruleName" -ForegroundColor Cyan
    }
    else {
        Write-Host "Ignoring default rule $ruleName" -VerboseOnly
    }
}
if ($count -gt 0) {
    Write-Host "Removed all firewall rules from server '%SQL_NAME%'." -ForegroundColor Green
} else {
    Write-Host "No removable rules where found on server '%SQL_NAME%'." -ForegroundColor Yellow
}
if ($locks) {
    Write-Host "Re-adding no-delete-rules for resource group..." -NoNewline
    Restore-CafLocks -Locks $locks
    Write-Host "Done"
}
else {
    Write-Host "Skipping re-adding of locks because no locks where found prior to the operation." -Verbose
}
