metadata templateInfo = {
  author: 'Paul McCormack'
  contact: 'https://github.com/paul-mccormack'
  description: 'Bicep template for deploying storage account for Azure Inventory Automation'
  date: '9-10-25'
  version: '1.0'
}

//
// User Defined Types
//

@description('User defined type to restrict Minimum TLS version to acceptable values')
type minimumTlsVersionType = 'TLS1_2' | 'TLS1_3'

//
// Parameters
//

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Storage Account name prefix. Name will be suffixed with a unique identifier to ensure global uniqueness.')
@minLength(3)
@maxLength(11)
param storageAccountNamePrefix string

@description('Storage Account SKU using resourceInput function')
param storageSkuType resourceInput<'Microsoft.Storage/storageAccounts@2025-01-01'>.sku.name

@description('Storage Account kind using resourceInput function')
param storageKindType resourceInput<'Microsoft.Storage/storageAccounts@2025-01-01'>.kind

@description('Storage Account access tier using resourceInput function')
param accessTierType resourceInput<'Microsoft.Storage/storageAccounts@2025-01-01'>.properties.accessTier

@description('Storage account public network access using resourceInput function')
param publicNetworkAccess resourceInput<'Microsoft.Storage/storageAccounts@2025-01-01'>.properties.publicNetworkAccess

@description('Storage account tls version from User Defined Type')
param storageTlsVersion minimumTlsVersionType

@description('Array of blob containers to create in the storage account')
param containers array

//
// variables
//

@description('Generate a globally unique storage account name by appending a unique string to the provided prefix. The name is converted to lowercase and truncated to 24 characters to meet Azure naming requirements.')
var storageAccountName = take(toLower('${storageAccountNamePrefix}${uniqueString(resourceGroup().id)}'), 24)

//
// Resources
//

@description('Storage Account for Azure Inventory Automation')
resource stg 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageSkuType
  }
  kind: storageKindType
  properties: {
    accessTier: accessTierType
    minimumTlsVersion: storageTlsVersion
    publicNetworkAccess: publicNetworkAccess
    supportsHttpsTrafficOnly: true
  }
}

@description('Blob service for the storage account')
resource blob 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  name: 'default'
  parent: stg
}

@description('Blob containers in the storage account')
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [for containerName in containers: {
  name: containerName
  parent: blob
  properties: {
    publicAccess: 'None'
  }
}]

//
// Outputs
//

@description('Name of the storage account')
output storageAccountName string = stg.name

@description('Resource ID of the storage account')
output storageAccountId string = stg.id
