# Azure Inventory Automation Project

This project has been setup to define, deploy and manage a solution to periodically run an automated inventory of SCC Azure resources. The project is based on the following solution [Azure Resource Inventory](https://github.com/Azure/azure-resource-inventory).

The solution will use the following Azure services:

- An Azure Automation Account to host and run the inventory script.
- An Azure Storage Account to store the inventory results.

The CI/CD pipeline in this project will create the resources and assign the necessary role assignments to the Automation Account, enabling it to create the output files in the storage account.

> ALERT: The Automation account will require reader access to the top level management groups or subscriptions to be inventoried. This will need to be completed manually after the deployment.


# Azure Resource Inventory PowerShell Module function

The code snip below show the PowerShell script that will be automated to run the inventory report.

```powershell
Import-Module AzureResourceInventory

# Import storage account name from Automation Account variables
$stg = Get-AutomationVariable -Name 'storageAccountName'

# Ensures you do not inherit an AzContext in your runbook  
Disable-AzContextAutosave -Scope Process | Out-Null  

# Connect using a Managed Service Identity  
try {  
        Connect-AzAccount -Identity  
}  
catch{  
        Write-Output "There is no system-assigned user identity. Aborting.";   
        exit  
}  

# Get Azure tenant ID
$tenantId = Get-AzTenant | Select-Object -ExpandProperty TenantId

# Run Azure Resource Inventory
Invoke-ARI -TenantID $tenantId -Automation -SecurityCenter -IncludeCosts -StorageAccount $stg -StorageContainer "reports"
```

The script is can be found here: [ps/ari_runbook.ps1](https://github.com/paul-mccormack/AzureAutomationARI/blob/main/ps/ari_runbook.ps1).

The name of the storage account is generated dynamically during the deployment and passed to the runbook as an Automation Account variable named `storageAccountName`. The automation account will use a System Assigned Managed Identity to authenticate to Azure and run the inventory.

# Deployment Details

This deployment will need to be run as multiple separate stages due to the requirement to populate the PowerShell script into the storage account after it has been created and before the automation account can be created. These are:

1. Deploy the resource group.
2. Check the resource bicep templates for errors and best practices.
3. Deploy the storage account and create blob containers for the scripts and reports.
4. Upload the PowerShell script to the storage account scripts container.
5. Deploy and configure the automation account and runbook.

The pipeline is defined in [deploy.yml](https://github.com/paul-mccormack/AzureAutomationARI/blob/main/.github/workflows/deploy.yml).

## Deploy Resource Group Stage

This is performed at the first stage of the pipeline using the `AzureResourceManagerTemplateDeployment@3` task. The resource group and location are defined as pipeline variables and the tags are passed to the deploy within the `overrideParameters` input.

## Bicep Pre-Deployment Checks Stage

The stage is to check the bicep deployment files for errors and best practices. Any warnings at this stage will be displayed in the build log. Any errors will cause the job to fail.

## Deployment Stage

This stage is more complicated than the previous stages. It's broken down into multiple jobs to perform the deployment of the storage account, upload of the PowerShell script from this repo and deployment of the automation account, runbook, and schedule. The runbook is pulled from the storage account at deployment time. It's also further complicated in that the later jobs require information that's generated dynamically during the deployment, these are the storage account name, the storage account access key and the URI including the SAS token of the PowerShell script in the storage account.

### Deploy Storage Account job

This job uses the `AzureResourceManagerTemplateDeployment@3` task to deploy the storage account and create the scripts and reports blob containers.

```yml
- job: DeployStorage  # Deploy Storage Account, blob containers and obtain outputs
  displayName: 'Deploy Storage Account and Blob Containers'
  steps:
    - task: AzureResourceManagerTemplateDeployment@3
      displayName: 'Deploy Storage Account and Blob Containers'
      inputs:
        deploymentScope: Resource Group
        azureResourceManagerConnection: $(service-connection)
        subscriptionId: $(subscriptionId)
        location: $(location)
        resourceGroupName: $(rgName)
        templateLocation: 'Linked artifact'
        csmFile: 'bicep/stg.bicep'
        csmParametersFile: 'bicep/stg.bicepparam'
        deploymentMode: Incremental
        deploymentOutputs: stgOutputs
```

Storage Accounts in Azure are required to have a globally unique name. To ensure this it's good practice to append a random string to the name.

```bicep
@description('Storage Account name prefix. Name will be suffixed with a unique identifier to ensure global uniqueness.')
@minLength(3)
@maxLength(11)
param storageAccountNamePrefix string

@description('Generate a globally unique storage account name by appending a unique string to the provided prefix. The name is converted to lowercase and truncated to 24 characters to meet Azure naming requirements.')
var storageAccountName = take(toLower('${storageAccountNamePrefix}${uniqueString(resourceGroup().id)}'), 24)

@description('Storage Account for Azure Inventory Automation')
resource stg 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  /
  /
}

@description('Name of the storage account')
output storageAccountName string = stg.name
```

The full bicep template can be found in [stg.bicep](https://dev.azure.com/scc-ddat-infrastructure/_git/AzureInventoryAutomation?path=/bicep/stg.bicep).

The storage account name is output from the deployment and captured in the `stgOutputs` variable. The next task runs a PowerShell loop to extract the outputs and save them to pipeline variables for use in later jobs.

```yml
- task: PowerShell@2
  name: StgOutputs
  displayName: Obtain Azure Deployment outputs
  inputs:
    targetType: 'inline'
    script: |
      if (![string]::IsNullOrEmpty( '$(stgOutputs)' )) {
        $DeploymentOutputs = convertfrom-json '$(stgOutputs)'
        $DeploymentOutputs.PSObject.Properties | ForEach-Object {
            $keyname = $_.Name
            $value = $_.Value.value
            Write-Host "##vso[task.setvariable variable=$keyname;isOutput=true]$value"
        }
      }
```

### Stage Script stage

The function of this job is to upload the PowerShell script from this repo to the `scripts` blob container. Before that can succeed the storage account access key is required to enable the DevOps pipeline agent to access the storage account. The storage account name generated in the previous job is passed into this job as a dependency output variable.

```yml
variables:
  pipelineVarStorageAccountName: $[ dependencies.DeployStorage.outputs['StgOutputs.storageAccountName'] ]
```

The job then uses an inline PowerShell script to retrieve the access key and save it to a variable called `$stgkey`.

```powershell
$saName = "$(pipelineVarStorageAccountName)"
$stgkey = Get-AzStorageAccountKey -ResourceGroupName $(rgName) -Name $saName | Where-Object {$_.KeyName -eq "key1"}
```

The script then creates a storage context and uploads the PowerShell script to the `scripts` container.

```powershell
$storageContext = New-AzStorageContext -StorageAccountName $saName -StorageAccountKey $stgkey.Value
Set-AzStorageBlobContent -File "ps/ari_runbook.ps1" -Container "scripts" -Context $storageContext -Force
```

Then it generates a Blob SAS URI and token with a 1 hour expiration for the uploaded script and saves it to a variable called `$blobUri`.

```powershell
$startTime = Get-Date
$endTime = $startTime.AddHours(1)
$blobUri = New-AzStorageBlobSASToken -Container "scripts" -Blob "ari_runbook.ps1" -Context $storageContext -Permission "r" -StartTime $startTime -ExpiryTime $endTime -FullUri
```

Then generate a file hash value of the PowerShell script which is required to successfully deploy it to the automation account runbook.

```powershell
$fileHash = Get-FileHash -Path "ps/ari_runbook.ps1" -Algorithm SHA256
$fileHashOutput = $fileHash.Hash
```
Finally, all the required output variables are saved to pipeline variables for use in the next job.

```powershell
Write-Host "##vso[task.setvariable variable=blobSasUriOutput;isOutput=true]$blobUri"
Write-Host "##vso[task.setvariable variable=blobHashOutput;isOutput=true]$fileHashOutput"
Write-Host "##vso[task.setvariable variable=saNameOutput;isOutput=true]$saName"
```

The complete task is shown below.

```yml
- task: AzurePowerShell@5
  name: StageScriptsTask
  displayName: 'Upload PowerShell Scripts to Storage Account'
  inputs:
    azureSubscription: $(service-connection)
    ScriptType: 'InlineScript'
    Inline: |
      $saName = "$(pipelineVarStorageAccountName)"
      $stgkey = Get-AzStorageAccountKey -ResourceGroupName $(rgName) -Name $saName | Where-Object {$_.KeyName -eq "key1"}
      $storageContext = New-AzStorageContext -StorageAccountName $saName -Protocol Https -StorageAccountKey $stgkey.Value
      Set-AzStorageBlobContent -File "ps/ari_runbook.ps1" -Container "scripts" -Context $storageContext -Force
      $startTime = Get-Date
      $endTime = $startTime.AddHours(1)
      $blobUri = New-AzStorageBlobSASToken -Container "scripts" -Blob "ari_runbook.ps1" -Context $storageContext -Permission "r" -StartTime $startTime -ExpiryTime $endTime -FullUri
      $fileHash = Get-FileHash -Path "ps/ari_runbook.ps1" -Algorithm SHA256
      $fileHashOutput = $fileHash.Hash
      Write-Host "##vso[task.setvariable variable=blobSasUriOutput;isOutput=true]$blobUri"
      Write-Host "##vso[task.setvariable variable=blobHashOutput;isOutput=true]$fileHashOutput"
      Write-Host "##vso[task.setvariable variable=saNameOutput;isOutput=true]$saName"
    azurePowerShellVersion: 'LatestVersion'
    pwsh: true
  ```

### Deploy main resources stage

The final job in this stage deploys the automation account, runbook and schedule. It requires the storage account name, the blob SAS URI and the file hash of the PowerShell script to be passed in as dependency output variables.

```yml
variables:
  pipelineVarStorageAccountName: $[ dependencies.DeployStorage.outputs['StgOutputs.storageAccountName'] ]
  pipelineVarBlobSasUri: $[ dependencies.StageScripts.outputs['StageScriptsTask.blobSasUriOutput'] ]
  pipelineVarBlobHash: $[ dependencies.StageScripts.outputs['StageScriptsTask.blobHashOutput'] ]
```

The job uses the `AzureResourceManagerTemplateDeployment@3` task to deploy the resources using the bicep template `bicep/main.bicep`. The required parameters are passed into the deployment using the `overrideParameters` input. The task configuration is shown below.

```yml
- task: AzureResourceManagerTemplateDeployment@3
  displayName: 'Deploy Main Resources'
  inputs:
    deploymentScope: Resource Group
    azureResourceManagerConnection: $(service-connection)
    subscriptionId: $(subscriptionId)
    location: $(location)
    resourceGroupName: $(rgName)
    templateLocation: Linked artifact
    csmFile: 'bicep/main.bicep'
    overrideParameters: -existingStorageAccountName $(pipelineVarStorageAccountName) -runbookScriptUri $(pipelineVarBlobSasUri) -runbookScriptHash $(pipelineVarBlobHash)
    deploymentMode: Incremental
```

The bicep template is located here: [main.bicep](https://dev.azure.com/scc-ddat-infrastructure/_git/AzureInventoryAutomation?path=/bicep/main.bicep).