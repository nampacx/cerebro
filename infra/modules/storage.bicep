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
param fileDnsZoneId string
@description('Name of the Function App content file share. WEBSITE_CONTENTOVERVNET=1 stops the platform from creating this share itself, so it has to exist before the app starts.')
param contentShareName string
@description('Azure Table that indexes Foundry conversation ids per user (PartitionKey = user object id).')
param conversationsTableName string = 'conversations'
@description('Queue carrying ingestion context (owner, document id, blob name) from the upload endpoint to the document-processing function. Must match the literal queue name in ProcessDocumentFunction\'s [QueueTrigger].')
param documentProcessingQueueName string = 'document-processing'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
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

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

resource documentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: documentsContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: blobService
  name: 'app-package-deployments'
  properties: {
    publicAccess: 'None'
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
}

resource documentProcessingQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2025-08-01' = {
  parent: queueService
  name: documentProcessingQueueName
}

// WEBSITE_CONTENTOVERVNET=1 routes the content share mount through the VNet, and in that
// mode the Functions platform cannot create the share on its own. Without it the app never
// mounts C:\home, which surfaces as Kudu returning 500s and the app hanging.
resource contentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-08-01' = {
  parent: fileService
  name: contentShareName
}

resource conversationsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2025-08-01' = {
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

// The Elastic Premium plan mounts WEBSITE_CONTENTSHARE over the VNet
// (WEBSITE_CONTENTOVERVNET=1), so the file endpoint has to be reachable privately
// or the app never mounts C:\home and Kudu fails with access denied.
module filePrivateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-file-${storageAccountName}'
  params: {
    location: location
    name: 'pe-file-${storageAccountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: storageAccount.id
    groupId: 'file'
    dnsZoneIds: [fileDnsZoneId]
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
output documentProcessingQueueName string = documentProcessingQueue.name
