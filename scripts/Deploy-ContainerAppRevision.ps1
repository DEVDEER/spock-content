#Requires -Version 7.0

<#
.SYNOPSIS
    Performs a blue/green deployment of an Azure Container App revision.

.DESCRIPTION
    Rolls out a new image in two phases, mirroring what deployment slots do for
    Azure App Services.

    Apps that do work without being called - queue consumers, timers, scheduled
    jobs - start doing that work as soon as a revision exists, long before it
    receives any traffic. To keep that work switched off until the image has
    proven itself, the rollout runs as:

      1. A staging revision is created with -DeploySlotVariable set to
         -StagingSlotValue, so the application knows it is not live yet, and it
         carries the full health check.
      2. Once it reports healthy, the production revision is created with
         -ProductionSlotValue and gets a shorter health check.
      3. Ingress traffic moves to the production revision, the staging revision
         is deactivated, and optionally so are the previously active revisions.

    Container App revisions are immutable, so phase two is necessarily a second
    revision rather than a restart of the first one with different settings.

    Any failure deactivates every revision this script created and leaves the
    traffic on the revision that was already serving it.

    Requires the container app to run in 'Multiple' revision mode and to have
    health probes configured. The application must read -DeploySlotVariable and
    gate its background work on it, otherwise the staging phase verifies nothing
    the production phase would not have caught.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory = $true)]
    [string]$ContainerAppName,
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$RevisionSuffix,
    [ValidateRange(1, 3600)]
    [int]$ReadinessTimeoutSeconds = 600,
    [ValidateRange(1, 300)]
    [int]$ReadinessIntervalSeconds = 10,
    # Deactivates all previously active revisions after the successful cutover so they stop consuming replicas.
    [switch]$DeactivateOldRevisions,

    # Name of the environment variable the application reads to decide whether it
    # already serves production traffic and may start its background work.
    [ValidateNotNullOrEmpty()]
    [string]$DeploySlotVariable = 'DEPLOY_SLOT',

    # Value the staging revision starts with (background work disabled).
    [ValidateNotNullOrEmpty()]
    [string]$StagingSlotValue = '1',

    # Value the production revision starts with (background work enabled).
    [ValidateNotNullOrEmpty()]
    [string]$ProductionSlotValue = '0',

    # Health check timeout for the production revision. Deliberately shorter than
    # -ReadinessTimeoutSeconds: the image already proved that it boots during the
    # staging phase, and every second spent here is a second in which the
    # production revision runs its background work alongside the previous
    # revision, which is still active and doing the same work.
    [ValidateRange(1, 3600)]
    [int]$ProductionReadinessTimeoutSeconds = 180
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Runs an Azure CLI command and returns its trimmed stdout.
    .PARAMETER Arguments
        The Azure CLI arguments to execute.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )
    Write-Host "az $($Arguments -join ' ')"
    # --only-show-errors keeps warnings (e.g. extension update notices) out of
    # stdout so tsv output can be parsed safely.
    $stdErrFile = New-TemporaryFile
    try {
        $output = & az @Arguments --only-show-errors 2> $stdErrFile.FullName
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $stdErr = (Get-Content -Path $stdErrFile.FullName -Raw -ErrorAction SilentlyContinue ?? '').Trim()
            throw "Azure CLI command failed with exit code ${exitCode}: $stdErr"
        }
        return ($output | Out-String).Trim()
    }
    finally {
        Remove-Item -Path $stdErrFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-RevisionSuffix {
    <#
    .SYNOPSIS
        Normalizes and validates the requested revision suffix.
    .PARAMETER ProvidedSuffix
        An optional suffix supplied by the caller.
    #>
    param([string]$ProvidedSuffix)
    $suffix = if (-not [string]::IsNullOrWhiteSpace($ProvidedSuffix)) {
        (($ProvidedSuffix.ToLowerInvariant() -replace '[^a-z0-9-]', '-') -replace '-+', '-').Trim('-')
    }
    else {
        "cd$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    }
    if ([string]::IsNullOrWhiteSpace($suffix)) {
        throw 'The resolved revision suffix is empty.'
    }
    # Suffix must start with a lowercase letter or digit; the full revision name
    # (app name + suffix) is capped at 63 characters.
    if ($suffix -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "The resolved revision suffix '$suffix' is invalid. It must start with a lowercase letter or digit and contain only lowercase letters, digits, and hyphens."
    }
    return $suffix
}

function Assert-MultipleRevisionMode {
    <#
    .SYNOPSIS
        Verifies that the container app uses multiple revision mode.
    .DESCRIPTION
        Read-only check. The revision mode is part of the infrastructure and is
        owned by the Bicep templates, so this function never modifies the app.
    .PARAMETER ContainerAppName
        The container app whose revision mode is checked.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )
    $revisionMode = Invoke-AzCli -Arguments @(
        'containerapp', 'show',
        '--name', $ContainerAppName,
        '--resource-group', $ResourceGroup,
        '--query', 'properties.configuration.activeRevisionsMode',
        '-o', 'tsv'
    )
    if ($revisionMode -eq 'Multiple') {
        Write-Host "Container app '$ContainerAppName' is in 'Multiple' revision mode."
        return
    }
    throw "Container app '$ContainerAppName' must be in 'Multiple' revision mode for blue/green deployments (current mode: '$revisionMode'). In 'Single' mode traffic switches immediately on update, which defeats the health gate. Set 'configActiveRevisionsMode' to 'Multiple' in the Bicep template and deploy the infrastructure before running this deployment."
}

function New-Revision {
    <#
    .SYNOPSIS
        Creates a new revision of the container app from the given image.
    .PARAMETER RevisionSuffix
        The suffix identifying the revision to create.
    .PARAMETER EnvironmentVariable
        Optional 'KEY=VALUE' assignments applied on top of the environment that
        is already configured on the app. Variables that are not listed keep the
        value the Bicep deployment gave them.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper of a deployment script that has no -WhatIf mode; every other mutating call in this script is unconditional too.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$Image,

        [Parameter(Mandatory = $true)]
        [string]$RevisionSuffix,

        [string[]]$EnvironmentVariable = @()
    )
    # Azure caps the full revision name, so catch an overlong suffix here rather
    # than in the middle of the rollout.
    $expectedName = "$ContainerAppName--$RevisionSuffix"
    if ($expectedName.Length -gt 63) {
        throw "The revision name '$expectedName' is $($expectedName.Length) characters long but Azure caps revision names at 63. Shorten the container app name or the revision suffix."
    }
    $arguments = @(
        'containerapp', 'update',
        '--name', $ContainerAppName,
        '--resource-group', $ResourceGroup,
        '--image', $Image,
        '--revision-suffix', $RevisionSuffix
    )
    if ($EnvironmentVariable.Count -gt 0) {
        # --set-env-vars only adds or updates the listed variables. Everything
        # else the app is configured with stays as it is.
        $arguments += '--set-env-vars'
        $arguments += $EnvironmentVariable
    }
    $arguments += @('--query', 'properties.latestRevisionName', '-o', 'tsv')
    $revisionName = Invoke-AzCli -Arguments $arguments
    if ([string]::IsNullOrWhiteSpace($revisionName)) {
        throw "The update command did not return the name of the new revision for suffix '$RevisionSuffix'."
    }
    if (-not $revisionName.EndsWith("-$RevisionSuffix")) {
        throw "The latest revision '$revisionName' does not match the requested suffix '$RevisionSuffix'. Another deployment may be running concurrently."
    }
    return $revisionName
}

function Show-RevisionLog {
    <#
    .SYNOPSIS
        Prints container logs for a specific revision when available.
    .PARAMETER RevisionName
        The revision whose logs should be displayed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$RevisionName,

        [int]$TailLines = 200
    )

    try {
        Write-Host "Attempting to fetch container logs for revision '$RevisionName'..."
        $logs = Invoke-AzCli -Arguments @(
            'containerapp', 'logs', 'show',
            '--name', $ContainerAppName,
            '--resource-group', $ResourceGroup,
            '--revision', $RevisionName,
            '--tail', $TailLines.ToString()
        )

        if (-not [string]::IsNullOrWhiteSpace($logs)) {
            Write-Host "Container logs for revision '$RevisionName':"
            Write-Host $logs
        }
        else {
            Write-Warning "No container logs were returned for revision '$RevisionName'."
        }
    }
    catch {
        Write-Warning "Unable to retrieve container logs for revision '$RevisionName': $($_.Exception.Message)"
    }
}

function Wait-RevisionHealthy {
    <#
    .SYNOPSIS
        Waits until a revision reaches Running and Healthy state.
    .PARAMETER RevisionName
        The revision to monitor.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,

        [Parameter(Mandatory = $true)]
        [string]$RevisionName,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Invoke-AzCli -Arguments @(
            'containerapp', 'revision', 'show',
            '--revision', $RevisionName,
            '--resource-group', $ResourceGroup,
            '--query', '{running: properties.runningState, health: properties.healthState}',
            '-o', 'json'
        ) | ConvertFrom-Json

        if ($state.running -match 'Failed|Terminated|Degraded|Stopped') {
            Show-RevisionLog -ContainerAppName $ContainerAppName -ResourceGroup $ResourceGroup -RevisionName $RevisionName
            throw "Revision '$RevisionName' ended in state '$($state.running)'."
        }

        if ($state.health -eq 'Unhealthy') {
            Show-RevisionLog -ContainerAppName $ContainerAppName -ResourceGroup $ResourceGroup -RevisionName $RevisionName
            throw "Revision '$RevisionName' reported healthState 'Unhealthy'. Check the readiness/startup probe results and container logs."
        }

        if ($state.running -in @('Running', 'RunningAtMaxScale')) {
            if ($state.health -eq 'Healthy') {
                Write-Host "Revision '$RevisionName' is Running and Healthy."
                return
            }
            if ($state.health -eq 'None') {
                # Without probes healthState never becomes 'Healthy', so there
                # would be no health gate at all.
                throw "Revision '$RevisionName' has no health probes configured (healthState 'None'). Configure a readiness probe on the container app."
            }
        }

        Write-Host "Revision '$RevisionName' is in state '$($state.running)' with healthState '$($state.health)'. Waiting..."
        Start-Sleep -Seconds $IntervalSeconds
    }

    Show-RevisionLog -ContainerAppName $ContainerAppName -ResourceGroup $ResourceGroup -RevisionName $RevisionName
    throw "Timed out after $TimeoutSeconds seconds while waiting for revision '$RevisionName' to become Running and Healthy."
}

function Disable-Revision {
    <#
    .SYNOPSIS
        Deactivates a specific container app revision.
    .PARAMETER RevisionName
        The revision to deactivate.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RevisionName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )
    Invoke-AzCli -Arguments @(
        'containerapp', 'revision', 'deactivate',
        '--revision', $RevisionName,
        '--resource-group', $ResourceGroup
    ) | Out-Null
}

# --- Main ---

Assert-MultipleRevisionMode `
    -ContainerAppName $ContainerAppName `
    -ResourceGroup $ResourceGroup

$revisionSuffix = Resolve-RevisionSuffix -ProvidedSuffix $RevisionSuffix

# Remember the currently active revisions so old revisions can be deactivated
# after a successful cutover.
$previouslyActiveRevisions = @(
    (Invoke-AzCli -Arguments @(
        'containerapp', 'revision', 'list',
        '--name', $ContainerAppName,
        '--resource-group', $ResourceGroup,
        '--query', '[?properties.active].name',
        '-o', 'tsv'
    )) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

# Every revision this script creates, so that a failure at any point can clean up
# all of them and never leaves a half finished rollout behind.
$createdRevisions = [System.Collections.Generic.List[string]]::new()
$revisionName = $null
try {
    # Phase 1: staging revision. Same image as the production revision, but the
    # application is told it is not live so background work stays off while the
    # image proves that it boots and that its dependencies are reachable.
    $stagingSuffix = "$revisionSuffix-stage"
    Write-Host "Creating staging revision with suffix '$stagingSuffix' ($DeploySlotVariable=$StagingSlotValue)."
    $stagingRevision = New-Revision `
        -ContainerAppName $ContainerAppName `
        -ResourceGroup $ResourceGroup `
        -Image $Image `
        -RevisionSuffix $stagingSuffix `
        -EnvironmentVariable @("$DeploySlotVariable=$StagingSlotValue")
    $createdRevisions.Add($stagingRevision)
    Write-Host "Waiting for staging revision '$stagingRevision' to become Running and Healthy."
    Wait-RevisionHealthy `
        -ContainerAppName $ContainerAppName `
        -ResourceGroup $ResourceGroup `
        -RevisionName $stagingRevision `
        -TimeoutSeconds $ReadinessTimeoutSeconds `
        -IntervalSeconds $ReadinessIntervalSeconds

    # Phase 2: production revision. Only the slot variable differs from the
    # staging revision that was just verified.
    Write-Host "Creating production revision with suffix '$revisionSuffix' ($DeploySlotVariable=$ProductionSlotValue)."
    $revisionName = New-Revision `
        -ContainerAppName $ContainerAppName `
        -ResourceGroup $ResourceGroup `
        -Image $Image `
        -RevisionSuffix $revisionSuffix `
        -EnvironmentVariable @("$DeploySlotVariable=$ProductionSlotValue")
    $createdRevisions.Add($revisionName)

    Write-Host "Waiting for production revision '$revisionName' to become Running and Healthy."
    Wait-RevisionHealthy `
        -ContainerAppName $ContainerAppName `
        -ResourceGroup $ResourceGroup `
        -RevisionName $revisionName `
        -TimeoutSeconds $ProductionReadinessTimeoutSeconds `
        -IntervalSeconds $ReadinessIntervalSeconds

    Write-Host "Switching traffic to revision '$revisionName' at 100%."
    Invoke-AzCli -Arguments @(
        'containerapp', 'ingress', 'traffic', 'set',
        '--name', $ContainerAppName,
        '--resource-group', $ResourceGroup,
        '--traffic-weight', "$revisionName=100"
    ) | Out-Null
}
catch {
    foreach ($createdRevision in $createdRevisions) {
        try {
            Disable-Revision -RevisionName $createdRevision -ResourceGroup $ResourceGroup
            Write-Host "Deactivated revision '$createdRevision' after rollout failure."
        }
        catch {
            Write-Warning "Failed to deactivate revision '$createdRevision': $($_.Exception.Message)"
        }
    }
    throw
}

# The staging revision has done its job once traffic is on the production
# revision. It is deactivated regardless of -DeactivateOldRevisions because this
# script created it and nothing else will ever clean it up.
foreach ($createdRevision in $createdRevisions) {
    if ($createdRevision -eq $revisionName) {
        continue
    }
    try {
        Disable-Revision -RevisionName $createdRevision -ResourceGroup $ResourceGroup
        Write-Host "Deactivated staging revision '$createdRevision'."
    }
    catch {
        Write-Warning "Failed to deactivate staging revision '$createdRevision': $($_.Exception.Message)"
    }
}

if ($DeactivateOldRevisions) {
    foreach ($oldRevision in $previouslyActiveRevisions) {
        if ($oldRevision -eq $revisionName) {
            continue
        }
        try {
            Disable-Revision -RevisionName $oldRevision -ResourceGroup $ResourceGroup
            Write-Host "Deactivated old revision '$oldRevision'."
        }
        catch {
            # Not fatal: the deployment itself succeeded, the old revision just
            # keeps running (and billing) until deactivated manually.
            Write-Warning "Failed to deactivate old revision '$oldRevision': $($_.Exception.Message)"
        }
    }
}

Write-Host "Deployment of revision '$revisionName' completed successfully."
