# Shortcut for the Start-Sleep which takes seconds only.
#
# Copyright DEVDEER GmbH 2023
# Latest update: 2023-03-25

param(
    [string] [Parameter(Mandatory = $true)] $Seconds
)

Start-Sleep -Seconds $Seconds