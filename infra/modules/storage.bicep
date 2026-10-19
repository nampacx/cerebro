@description('Storage account for documents and function runtime.')
param location string
param storageAccountName string
param tags object = {}
param documentsContainerName string = 'documents'
@description('Name of the Function App content file share.')
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
    publicNetworkAccess: 'Enabled'
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

resource contentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-08-01' = {
  parent: fileService
  name: contentShareName
}

resource conversationsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2025-08-01' = {
  parent: tableService
  name: conversationsTableName
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table
output queueEndpoint string = storageAccount.properties.primaryEndpoints.queue
output documentsContainerName string = documentsContainer.name
output conversationsTableName string = conversationsTable.name
output documentProcessingQueueName string = documentProcessingQueue.name
