metadata templateInfo = {
  author: 'Paul McCormack'
  email: 'paul.mccormack@salford.gov.uk'
  description: 'Bicep template module to apply a CanNotDelete lock to a resource group'
  date: '15-9-25'
  version: '1.0'
}

@description('Deploy a CanNotDelete lock to the resource group to prevent accidental deletion')
resource rglock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'NoDelete'
  properties: {
    level: 'CanNotDelete'
    notes: 'Resource Group Locked to prevent accidental deletion'
  }
}
