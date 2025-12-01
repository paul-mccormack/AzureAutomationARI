# Azure Inventory Automation Project

[![Deploy Azure Resource Inventory](https://github.com/paul-mccormack/AzureAutomationARI/actions/workflows/deploy.yml/badge.svg)](https://github.com/paul-mccormack/AzureAutomationARI/actions/workflows/deploy.yml)

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

1. Deploy the resource group and create a no delete lock.
2. Deploy the storage account and create blob containers for the scripts and reports.
3. Upload the PowerShell script to the storage account scripts container.
4. Deploy and configure the automation account and runbook.

The pipeline is defined in [deploy.yml](https://github.com/paul-mccormack/AzureAutomationARI/blob/main/.github/workflows/deploy.yml).

## Deploy Resource Group

This is performed at the first step of the pipeline using the `azure/bicep-deploy@v2` action. The resource group and location are defined as pipeline environment variables and the tags are passed to the deploy within the `parameters` input.

## Resource Deployments

This deployment is complicated due to requiring properties that are unknown at the start of the deployment. It's broken down into multiple steps to perform the deployment of the storage account, upload of the PowerShell script from this repo and perform the deployment of the automation account, runbook, and schedule. The runbook is pulled from the storage account at deployment time. Later steps require information that's generated dynamically during the deployment, these are the storage account name, the storage account access key and the URI including the SAS token of the PowerShell script in the storage account.

### Deploy Storage Account step

This step again uses the `azure/bicep-deploy@v2` action to deploy the storage account and create the scripts and reports blob containers.

```yml
- name: Deploy Storage Account
  id: deployStg
  uses: azure/bicep-deploy@v2
  with:
    type: deployment
    operation: create
    name: deploy-ari-storage
    scope: resourceGroup
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    resource-group-name: ${{ env.AZURE_RESOURCE_GROUP }}
    template-file: ./bicep/stg.bicep
    parameters-file: ./bicep/stg.bicepparam
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

The full bicep template can be found in [stg.bicep](https://github.com/paul-mccormack/AzureAutomationARI/blob/main/bicep/stg.bicep).

`azure/bicep-deploy@v2` action supports output variables from the Bicep template which can be referenced in later steps. The storage account name is saved to an output variable called `storageAccountName`, this is referenced in the next step using the step id: `"${{ steps.deployStg.outputs.storageAccountName }}"`.


### Stage Script stage

The function of this job is to upload the PowerShell script from this repo to the `scripts` blob container. Before that can succeed the storage account access key is required to enable the DevOps pipeline agent to access the storage account. The storage account name generated in the previous job is passed into this job as as detailed above.

The job then uses an inline PowerShell script to retrieve the access key and save it to a variable called `$stgkey`.

```powershell
$saName = "${{ steps.deployStg.outputs.storageAccountName }}"
$stgkey = Get-AzStorageAccountKey -ResourceGroupName ${{ env.AZURE_RESOURCE_GROUP }} -Name $saName | Where-Object {$_.KeyName -eq "key1"}
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
The final requirement of this step is to pass the blob SAS URI and file hash to the next jon in the pipeline.  This can be done by setting [output parameters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#setting-an-output-parameter).

```powershell
"blob_uri=$blobUri" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"file_hash=$fileHashOutput" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
```

As we are using PowerShell in this step we need to use  `$env:GITHUB_OUTPUT`.

The complete task is shown below.

```yml
- name: Deploy ARI Runbook Script to Storage Account
  id: uploadScript
  uses: azure/powershell@v2
  with:
    inlineScript: |
      $saName = "${{ steps.deployStg.outputs.storageAccountName }}"
      $stgkey = Get-AzStorageAccountKey -ResourceGroupName ${{ env.AZURE_RESOURCE_GROUP }} -Name $saName | Where-Object {$_.KeyName -eq "key1"}
      $storageContext = New-AzStorageContext -StorageAccountName $saName -Protocol Https -StorageAccountKey $stgkey.Value
      Set-AzStorageBlobContent -File "ps/ari_runbook.ps1" -Container "scripts" -Context $storageContext -Force
      $startTime = Get-Date
      $endTime = $startTime.AddHours(1)
      $blobUri = New-AzStorageBlobSASToken -Container "scripts" -Blob "ari_runbook.ps1" -Context $storageContext -Permission "r" -StartTime $startTime -ExpiryTime $endTime -FullUri
      $fileHash = Get-FileHash -Path "ps/ari_runbook.ps1" -Algorithm SHA256
      $fileHashOutput = $fileHash.Hash
      "blob_uri=$blobUri" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
      "file_hash=$fileHashOutput" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    azPSVersion: latest
  ```

### Deploy main resources stage

The final job in this stage deploys the automation account, runbook and schedule using the variables and step outputs generated during the deployment.

We can reference the `storageAccountName` output the same as before but the `GITHUB_OUTPUT` variables need to be defined as environment variables in this 

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


## Notes

See if I can drop the env variables in the last step and reference the output variables directly.

Talk about the powershell script to run ARI.

Talk about the storage automation account needing read access to the subscriptions or management groups being scanned.  