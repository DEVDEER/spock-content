#Requires -Version 7.0

<#
.SYNOPSIS
    Performs a blue/green deployment of an Azure Container App revision.

.DESCRIPTION
    Creates a new revision from the given image and waits until the platform
    reports it as Running and Healthy based on the health probes configured on
    the app, then shifts ingress traffic to it. On failure the new revision is
    deactivated. Optionally deactivates old revisions after a successful cutover.
    Requires the container app to run in 'Multiple' revision mode and to have
    health probes configured.
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
    [switch]$DeactivateOldRevisions
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

$revisionName = $null
try {
    Write-Host "Creating new revision with suffix '$revisionSuffix' for container app '$ContainerAppName'."
    $revisionName = Invoke-AzCli -Arguments @(
        'containerapp', 'update',
        '--name', $ContainerAppName,
        '--resource-group', $ResourceGroup,
        '--image', $Image,
        '--revision-suffix', $revisionSuffix,
        '--query', 'properties.latestRevisionName',
        '-o', 'tsv'
    )
    if ([string]::IsNullOrWhiteSpace($revisionName)) {
        throw "The update command did not return the name of the new revision for suffix '$revisionSuffix'."
    }
    if (-not $revisionName.EndsWith("-$revisionSuffix")) {
        throw "The latest revision '$revisionName' does not match the requested suffix '$revisionSuffix'. Another deployment may be running concurrently."
    }
    Write-Host "Waiting for revision '$revisionName' to become Running and Healthy."
    Wait-RevisionHealthy `
        -ContainerAppName $ContainerAppName `
        -ResourceGroup $ResourceGroup `
        -RevisionName $revisionName `
        -TimeoutSeconds $ReadinessTimeoutSeconds `
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
    if (-not [string]::IsNullOrWhiteSpace($revisionName)) {
        try {
            Disable-Revision -RevisionName $revisionName -ResourceGroup $ResourceGroup
            Write-Host "Deactivated revision '$revisionName' after rollout failure."
        }
        catch {
            Write-Warning "Failed to deactivate revision '$revisionName': $($_.Exception.Message)"
        }
    }
    throw
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
