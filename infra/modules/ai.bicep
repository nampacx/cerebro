@description('Microsoft Foundry (AI Services) account with project, chat + embedding deployments, and private endpoint. Document Intelligence is included in the AIServices multi-service account.')
param location string
param accountName string
param projectName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param cognitiveServicesDnsZoneId string
param openAiDnsZoneId string
param aiServicesDnsZoneId string

param chatModelDeploymentName string = 'gpt-5'
param chatModelName string = 'gpt-5'
param chatModelVersion string = ''
param chatModelCapacity int = 50
param embeddingModelDeploymentName string = 'text-embedding-3-large'
param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
param embeddingModelCapacity int = 120

@description('Enable customer-managed Foundry agent storage (Cosmos DB for conversation threads + Storage for artifacts).')
param useCustomFoundryStorage bool = true
@description('Resource id of the Cosmos DB account used for Foundry conversation thread storage.')
param cosmosAccountId string = ''
@description('Resource id of the Storage account used for Foundry agent artifacts.')
param storageAccountId string = ''

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: accountName
    allowProjectManagement: true
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: true
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
  }
}

var cosmosAccountName = empty(cosmosAccountId) ? '' : last(split(cosmosAccountId, '/'))
var storageAccountName = empty(storageAccountId) ? '' : last(split(storageAccountId, '/'))
var byoStorage = useCustomFoundryStorage && !empty(cosmosAccountId) && !empty(storageAccountId)

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (byoStorage) {
  name: byoStorage ? cosmosAccountName : 'placeholder'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (byoStorage) {
  name: byoStorage ? storageAccountName : 'placeholder'
}

resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (byoStorage) {
  parent: project
  name: cosmosAccountName
  properties: {
    category: 'CosmosDB'
    #disable-next-line BCP318
    target: byoStorage ? cosmosAccount.properties.documentEndpoint : ''
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmosAccountId
      location: location
    }
  }
}

resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (byoStorage) {
  parent: project
  name: storageAccountName
  properties: {
    category: 'AzureStorageAccount'
    #disable-next-line BCP318
    target: byoStorage ? storageAccount.properties.primaryEndpoints.blob : ''
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: storageAccountId
      location: location
    }
  }
}

resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = if (byoStorage) {
  parent: account
  name: '${accountName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
}

// vectorStoreConnections is intentionally omitted: retrieval is served by pgvector,
// so no Azure AI Search resource is required for this solution.
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = if (byoStorage) {
  parent: project
  name: '${projectName}-caphost'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    #disable-next-line BCP037
    threadStorageConnections: [cosmosAccountName]
    storageConnections: [storageAccountName]
  }
  dependsOn: [accountCapabilityHost, cosmosConnection, storageConnection]
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: chatModelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: chatModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: empty(chatModelVersion) ? null : chatModelVersion
    }
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: embeddingModelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: empty(embeddingModelVersion) ? null : embeddingModelVersion
    }
  }
  dependsOn: [chatDeployment]
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${accountName}'
  params: {
    location: location
    name: 'pe-${accountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: account.id
    groupId: 'account'
    dnsZoneIds: [
      cognitiveServicesDnsZoneId
      openAiDnsZoneId
      aiServicesDnsZoneId
    ]
    tags: tags
  }
}

output accountName string = account.name
output accountId string = account.id
output endpoint string = account.properties.endpoint
output openAiEndpoint string = 'https://${accountName}.openai.azure.com/'
output documentIntelligenceEndpoint string = 'https://${accountName}.cognitiveservices.azure.com/'
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
output accountPrincipalId string = account.identity.principalId
output chatDeploymentName string = chatDeployment.name
output embeddingDeploymentName string = embeddingDeployment.name

