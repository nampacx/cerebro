@description('Storage account for documents and function runtime, with blob private endpoint.')
param location string
param storageAccountName string
param tags object = {}
param documentsContainerName string = 'documents'
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param blobDnsZoneId string
param tableDnsZoneId string
param queueDnsZoneId string
@description('Azure Table that indexes Foundry conversation ids per user (PartitionKey = user object id).')
param conversationsTableName string = 'conversations'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource documentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: documentsContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'app-package-deployments'
  properties: {
    publicAccess: 'None'
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource conversationsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: conversationsTableName
}

module blobPrivateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-blob-${storageAccountName}'
  params: {
    location: location
    name: 'pe-blob-${storageAccountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: storageAccount.id
    groupId: 'blob'
    dnsZoneIds: [blobDnsZoneId]
    tags: tags
  }
}

module tablePrivateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-table-${storageAccountName}'
  params: {
    location: location
    name: 'pe-table-${storageAccountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: storageAccount.id
    groupId: 'table'
    dnsZoneIds: [tableDnsZoneId]
    tags: tags
  }
}

module queuePrivateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-queue-${storageAccountName}'
  params: {
    location: location
    name: 'pe-queue-${storageAccountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: storageAccount.id
    groupId: 'queue'
    dnsZoneIds: [queueDnsZoneId]
    tags: tags
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table
output queueEndpoint string = storageAccount.properties.primaryEndpoints.queue
output documentsContainerName string = documentsContainer.name
output conversationsTableName string = conversationsTable.name
