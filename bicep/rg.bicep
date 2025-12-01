metadata templateInfo = {
  author: 'Paul McCormack'
  contact: 'https://github.com/paul-mccormack'
  description: 'Bicep template for deploying a resource group for Azure Inventory Automation'
  date: '7-10-25'
  version: '1.0'
}

targetScope = 'subscription'

//
// Paramters
//

@description('Name of the resource group to create')
param rgName string

@description('Location for all resources.')
param location string

@description('Optional: The tags to be associated with the resource group. Minimum required tags are "Created By", "Cost Centre" and "Service".')
param tags object

//
// Resources
//

@description('Resource Group for Azure Inventory Automation')
resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgName
  location: location
  tags: tags
}

@description('Deploy a CanNotDelete lock to the resource group to prevent accidental deletion')
module lock 'modules/lock.bicep' = {
  scope: rg
}

//
// Outputs
//

@description('Name of the resource group')
output resourceGroupName string = rg.name

@description('Resource ID of the resource group')
output resourceGroupId string = rg.id
