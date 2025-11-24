using './stg.bicep'

param storageAccountNamePrefix = 'azinvauto'
param storageSkuType = 'Standard_LRS'
param storageKindType = 'StorageV2'
param accessTierType = 'Hot'
param publicNetworkAccess = 'Enabled'
param storageTlsVersion = 'TLS1_2'
param containers = [
  'reports'
  'scripts'
]

