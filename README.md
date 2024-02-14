# spock-content

## Summary

Provides public content for the internal project `Spock` and customer projects of [DEVDEER](https://devdeer.com). Some of the content provided here is downloaded directly by pipeline steps or inside other default scripts.

## Contribution

We don't accept external pull requests. This project is only used by DEVDEER and it's customers internally.

## Details

## check-health.ps1

This script is used in CD pipelines in order to check if an deployed slot health-endpoint delivers a healthy result before swapping it.

Usage

```powershell
check-health.ps1 -AppName api-xx-project -Stage int
```

The sample above assumes that an app is running in Azure listening on `https://api-xx-project-deploy.azurewebsites.net/health`.

You can implement this in your YAML pipelines as follows:

```yaml
- task: PowerShell@2
  displayName: 'Download health check script'
  inputs:
      targetType: 'inline'
      script: |
          mkdir -p "$(Pipeline.Workspace)/ci/drop/pipeline-scripts"
          curl https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/check-health.ps1 -o "$(Pipeline.Workspace)/ci/drop/pipeline-scripts/check-health.ps1"
      pwsh: true
      workingDirectory: '$(Pipeline.Workspace)'
```
## set-ado-prstate.ps1

This script is used to check and set the state of a pull request in Azure DevOps. This can be used e.g. to limit the completion of of pull requests to a full run of the corresponding release pipeline.

You can implement this in your YAML pipelines as follows:

### ci.yml
At the beginning:
```yaml
  - task: PowerShell@2    
    displayName: 'Update CD status'
    timeoutInMinutes: 1
    inputs:
      targetType: filePath
      filePath: '$(Build.SourcesDirectory)/.azuredevops/scripts/set-ado-prstate.ps1'
      arguments: '-TenantId $(TenantId) -CollectionUri $(System.CollectionUri) -ProjectName $(System.TeamProject) -PrincipalId $(PrincipalId) -PrincipalSecret $(PrincipalSecret) -PullRequestId $(pr) -StatusState "Waiting" -StatusDescription "CD is waiting for CI"'
      pwsh: true
      workingDirectory: '$(Build.SourcesDirectory)/.azuredevops/scripts/'
    condition: eq(variables['Build.Reason'], 'PullRequest')
```

At the end:
```yaml
  - task: PowerShell@2    
    displayName: 'Update CD status'
    timeoutInMinutes: 1
    inputs:
      targetType: filePath
      filePath: '$(Build.SourcesDirectory)/.azuredevops/scripts/set-ado-prstate.ps1'
      arguments: '-TenantId $(TenantId) -CollectionUri $(System.CollectionUri) -ProjectName $(System.TeamProject) -PrincipalId $(PrincipalId) -PrincipalSecret $(PrincipalSecret) -PullRequestId $(pr) -StatusState "Waiting" -StatusDescription "CD is waiting for Integration stage deployment"'
      pwsh: true
      workingDirectory: '$(Build.SourcesDirectory)/.azuredevops/scripts/'
    condition: eq(variables['Build.Reason'], 'PullRequest')
```

### backend-stage.yml template
```yaml
- task: PowerShell@2
displayName: 'Finish CD state'
timeoutInMinutes: 1
inputs:
    targetType: filePath
    filePath: '$(Pipeline.Workspace)/ci/drop/pipeline-scripts/set-ado-prstate.ps1'
    arguments: '-TenantId $(TenantId) -CollectionUri $(System.CollectionUri) -ProjectName $(System.TeamProject) -PrincipalId $(PrincipalId) -PrincipalSecret $(PrincipalSecret) -PullRequestId $(pr) -StatusState "Succeeded" -StatusDescription ""'
    pwsh: true
    workingDirectory: '$(Pipeline.Workspace)/ci/drop/pipeline-scripts'
condition: and(eq(variables['Agent.JobStatus'], 'Succeeded'), eq(variables['hasPR'], 'True'), eq('${{ parameters.StageShort }}', 'prod'))
```

### deployment.yml template
```yaml
    - task: PowerShell@2
      displayName: 'Update CD state'
      timeoutInMinutes: 1
      inputs:
        targetType: filePath
        filePath: '$(Pipeline.Workspace)/ci/drop/pipeline-scripts/set-ado-prstate.ps1'
        arguments: '-TenantId $(TenantId) -CollectionUri $(System.CollectionUri) -ProjectName $(System.TeamProject) -PrincipalId $(PrincipalId) -PrincipalSecret $(PrincipalSecret) -PullRequestId $(pr) -StatusState "Waiting" -StatusDescription "CD is deploying to ${{ parameters.StageShort }} stage"'
        pwsh: true
        workingDirectory: '$(Pipeline.Workspace)/ci/drop/pipeline-scripts'
      condition: eq(variables['hasPR'], 'True')
```

For the to work you need to add `TenantId`, `PrincipalId` and `PrincipalSecret` to the Variable Group of the project.

To make your fully compliant in working with pull requests and their state, you should add the following scripts to the beginning of the mentioned stages and adjust the `COMPANY_NAME` and `PROJECT_NAME`:

### preparation.yml
```yaml
    - task: AzurePowerShell@5
      inputs:
        Inline: |                            
          $hasPR = Test-Path pr.txt
          Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
          Write-Host "hasPR before if is $hasPR"
          if ($hasPR) {
            $pr = Get-Content -Raw pr.txt
            $pr = $pr.replace("`n","").replace("`r","")
            Write-Host "##vso[task.setvariable variable=pr;]$pr"
            Write-Host "PR number is $pr"
            # PR Url
            $url = "https://dev.azure.com/grzroche/Jever/_apis/git/repositories/Jever/pullRequests/" + $pr + "?api-version=7.0"
            #Authenticate to ADO
            $devOpsScopeGuid = "499b84ac-1321-427f-aa17-267ca6975798"
            $secureStringPwd = "$(PrincipalSecret)" | ConvertTo-SecureString -AsPlainText -Force
            $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "$(PrincipalId)", $secureStringPwd
            Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant "$(TenantId)"
            # Get the access token
            $token = (Get-AzAccessToken -ResourceUrl $devOpsScopeGuid).Token
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $headers.Add('Authorization',('Bearer {0}' -f $token))
            $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ContentType application/json
            $status = $response.status
            if ($status -ne "active") {
              $hasPR = $false
              Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
              Write-Host "hasPR is $hasPR"
            }
          }
        azureSubscription: ${{ parameters.ServiceConnectionName }}
        ScriptType: 'InlineScript'
        preferredAzurePowerShellVersion: '3.1.0'
        displayName: 'Checking for PR trigger'
        workingDirectory: $(Pipeline.Workspace)/ci/drop

```

### deployment.yml
```yaml
    - task: AzurePowerShell@5
      inputs:
        Inline: |                            
          $hasPR = Test-Path pr.txt
          Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
          if ($hasPR) {
            $pr = Get-Content -Raw pr.txt
            $pr = $pr.replace("`n","").replace("`r","")
            Write-Host "##vso[task.setvariable variable=pr;]$pr"
            Write-Host "PR number is $pr"
            $url = "https://dev.azure.com/grzroche/Jever/_apis/git/repositories/Jever/pullRequests/" + $pr + "?api-version=7.0"
            #Authenticate to ADO
            $devOpsScopeGuid = "499b84ac-1321-427f-aa17-267ca6975798"
            $secureStringPwd = "$(PrincipalSecret)" | ConvertTo-SecureString -AsPlainText -Force
            $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "$(PrincipalId)", $secureStringPwd
            Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant "$(TenantId)"
            # Get the access token
            $token = (Get-AzAccessToken -ResourceUrl $devOpsScopeGuid).Token
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $headers.Add('Authorization',('Bearer {0}' -f $token))
            $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ContentType application/json
            $status = $response.status
            if ($status -ne "active") {
              $hasPR = $false
              Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
              Write-Host "hasPR is $hasPR"
            }
          }
        azureSubscription: ${{ parameters.ServiceConnectionName }}
        ScriptType: 'InlineScript'
        preferredAzurePowerShellVersion: '3.1.0'
        displayName: 'Checking for PR trigger and reading PR'
        workingDirectory: $(Pipeline.Workspace)/ci/drop
```

### backent-stage.yml
```yaml
    - task: AzurePowerShell@5
      inputs:
        Inline: |
          $hasPR = Test-Path pr.txt
          Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
          if ($hasPR) {
            $pr = Get-Content -Raw pr.txt
            $pr = $pr.replace("`n","").replace("`r","")
            Write-Host "##vso[task.setvariable variable=pr;]$pr"
            Write-Host "PR number is $pr"
            $url = "https://dev.azure.com/grzroche/Jever/_apis/git/repositories/Jever/pullRequests/" + $pr + "?api-version=7.0"
            #Authenticate to ADO
            $devOpsScopeGuid = "499b84ac-1321-427f-aa17-267ca6975798"
            $secureStringPwd = "$(PrincipalSecret)" | ConvertTo-SecureString -AsPlainText -Force
            $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "$(PrincipalId)", $secureStringPwd
            Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant "$(TenantId)"
            # Get the access token
            $token = (Get-AzAccessToken -ResourceUrl $devOpsScopeGuid).Token
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $headers.Add('Authorization',('Bearer {0}' -f $token))
            $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ContentType application/json
            $status = $response.status
            if ($status -ne "active") {
                $hasPR = $false
                Write-Host "##vso[task.setvariable variable=hasPR;]$hasPR"
                Write-Host "hasPR is $hasPR"
            }
          }
        azureSubscription: ${{ parameters.ServiceConnectionName }}
        ScriptType: 'InlineScript'
        preferredAzurePowerShellVersion: '3.1.0'
        displayName: 'Checking for PR trigger and reading PR'
        workingDirectory: $(Pipeline.Workspace)/ci/drop
```

