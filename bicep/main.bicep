metadata templateInfo = {
  author: 'Paul McCormack'
  email: 'paul.mccormack@salford.gov.uk'
  description: 'Bicep template for deploying resources for Azure Inventory Automation'
  date: '7-10-25'
  version: '1.0'
}

//
// Parameters
//

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the Automation Account to be created.')
param automationAccountName string

@description('Name of an existing Storage Account to be used by the Automation Account for storing runbook output and pulling the ps script for the runbook. The Storage Account must have blob container named "reports" and "scripts".')
param existingStorageAccountName string

@description('Array of PowerShell modules to be installed in the Automation Account runtime environment')
param psPackages array = [
  {
    name: 'Az.Accounts'
    uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.3.0'
  }
  {
    name: 'Az.Compute'
    uri: 'https://www.powershellgallery.com/api/v2/package/Az.Compute/10.3.0'
  }
  {
    name: 'Az.CostManagement'
    uri: 'https://www.powershellgallery.com/api/v2/package/Az.CostManagement/0.4.2'
  }
  {
    name: 'Az.ResourceGraph'
    uri: 'https://www.powershellgallery.com/api/v2/package/Az.ResourceGraph/1.2.1'
  }
  {
    name: 'AzureResourceInventory'
    uri: 'https://www.powershellgallery.com/api/v2/package/AzureResourceInventory/3.6.11'
  }
  {
    name: 'Az.Storage'
    uri: 'https://www.powershellgallery.com/api/v2/package/Az.Storage/9.1.0'
  }
  {
    name: 'ImportExcel'
    uri: 'https://www.powershellgallery.com/api/v2/package/ImportExcel/7.8.10'
  }
  {
    name: 'PowerShellGet'
    uri: 'https://www.powershellgallery.com/api/v2/package/PowerShellGet/2.2.5'
  }
  {
    name: 'Microsoft.PowerShell.ThreadJob'
    uri: 'https://www.powershellgallery.com/api/v2/package/Microsoft.PowerShell.ThreadJob/2.2.0'
  }
  
]

@description('URI of the runbook script to be published in the Automation Account')
param runbookScriptUri string

@description('SHA256 hash of the runbook script for integrity verification')
param runbookScriptHash string

@description('Name of the schedule to run the Azure Resource Inventory runbook')
param scheduleName string = 'ARI_MonthlySchedule'

@description('Current date and time in UTC format')
param now string = utcNow('u')

//
// Variables
//

@description('Role ID for Storage Blob Data Contributor role')
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

@description('add 1 day to the current date to ensure the schedule start time is in the future')
var startTime = dateTimeAdd(now, 'P1D')

//
// Existing Resources
//

@description('Reference to an existing Storage Account')
resource stg 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: existingStorageAccountName
}

//
// Resources
//

@description('Automation Account for running the Azure Resource Inventory runbook')
resource automation 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

resource automationVariable 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  name: 'storageAccountName'
  parent: automation
  properties: {
    value: '"${existingStorageAccountName}"'   // Resource provider expects a JSON-serialized string so must be double quoted.  '"value"'
  }
}

@description('Runtime Environment for the Automation Account with PowerShell 7.4 and specified default packages')
resource runtimeEnv 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2023-05-15-preview' = {
  name: 'PowerShell74'
  parent: automation
  location: location
  properties: {
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {
      az: '12.3.0'
      'azure cli': '2.64.0'
    }
  }
}

@description('PowerShell packages to be installed in the Automation Account runtime environment')
resource packages 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2023-05-15-preview' = [for psPackage in psPackages: {
  name: psPackage.name
  parent: runtimeEnv
  properties: {
    contentLink: {
      uri: psPackage.uri
    }
  }
}]

@description('Runbook for generating Azure Resource Inventory and saving the output to the Storage Account')
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: 'AzureResourceInventory-Runbook'
  parent: automation
  location: location
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtimeEnv.name
    publishContentLink: {
      uri: runbookScriptUri
      version: '1.0'
      contentHash: {
       algorithm: 'SHA256'
       value: runbookScriptHash
      }
    }
  }
}

@description('Schedule to run the Azure Resource Inventory runbook monthly on the first Monday of each month')
resource schedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = {
  name: scheduleName
  parent: automation
  properties: {
    frequency: 'Month'
    interval: any(1)
    startTime: startTime
    timeZone: 'UTC'
    description: 'Monthly schedule to run the Azure Resource Inventory runbook'
  }
}

@description('Linking the schedule to the Azure Resource Inventory runbook')
resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = {
  name: guid(resourceGroup().id, schedule.id, runbook.id)
  parent: automation
  properties: {
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
  }
}

@description('Role Assignment to grant the Automation Account access to the Storage Account')
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: stg
  name: guid(automation.id, resourceGroup().id, stg.id)
  properties: {
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
  }
}


