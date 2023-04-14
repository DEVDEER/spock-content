# spock-content

## Summary

Provides public content for the internal project `Spock` and customer projects of [DEVDEER](https://devdeer.com). Some of the content provided here is downloaded directly by pipeline steps or inside other default scripts.

## Contribution

We don't accept external pull requests. This project is only used by DEVDEER and it's customers internally.

## Details

### check-health.ps1

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
          curl https://raw.githubusercontent.com/DEVDEER/spock-content/main/scripts/check-health.ps1 -o "$(Pipeline.Workspace)/ci/drop/pipeline-scripts/check-health.ps1"
      pwsh: true
      workingDirectory: '$(Pipeline.Workspace)'
```
