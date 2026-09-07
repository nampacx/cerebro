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
@description('Resource id of the delegated (Microsoft.App/environments) subnet the Agents capability host injects its agent client into, so calls to the BYO Cosmos/Storage/Search connections stay on the VNet. Required: without it, those calls leave over the public internet and are rejected once the BYO resources go private (see cosmos.bicep).')
param agentSubnetId string

param chatModelDeploymentName string = 'gpt-5'
param chatModelName string = 'gpt-5'
param chatModelVersion string = ''
param chatModelCapacity int = 50
param embeddingModelDeploymentName string = 'text-embedding-3-large'
param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
param embeddingModelCapacity int = 120

@description('Enable customer-managed Foundry agent storage (Cosmos DB for conversation threads + Storage for artifacts + AI Search for the agent vector store).')
param useCustomFoundryStorage bool = true
@description('Resource id of the Cosmos DB account used for Foundry conversation thread storage.')
param cosmosAccountId string = ''
@description('Resource id of the Storage account used for Foundry agent artifacts.')
param storageAccountId string = ''
@description('Resource id of the Azure AI Search service used for the Foundry agent vector store. Required whenever the other two are set: the Agents capability host rejects a partial connection set.')
param searchServiceId string = ''

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
    // Injects the Agents capability host's agent client into the VNet so its outbound calls to
    // the BYO Cosmos/Storage/Search connections travel over the private endpoints instead of
    // the public internet. Confirmed necessary: Cosmos DB rejected those calls once its private
    // endpoint was in place, even with publicNetworkAccess=Enabled and no IP/VNet rules, because
    // its "thin client" data plane enforces network rules more strictly once any private
    // endpoint exists - this account has to actually be on the VNet, not just publicly allowed.
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
      }
    ]
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
var searchServiceName = empty(searchServiceId) ? '' : last(split(searchServiceId, '/'))
// The Agents capability host validates threadStorage + storage + vectorStore as an atomic
// set ("All connections must be provided, else omitted"), so all three resource ids must be
// present before any of the connections or capability hosts are created.
var byoStorage = useCustomFoundryStorage && !empty(cosmosAccountId) && !empty(storageAccountId) && !empty(searchServiceId)

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2026-03-15' existing = if (byoStorage) {
  name: byoStorage ? cosmosAccountName : 'placeholder'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' existing = if (byoStorage) {
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

resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (byoStorage) {
  parent: project
  name: searchServiceName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${searchServiceName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServiceId
      location: location
    }
  }
}

// Every child write (capability hosts, model deployments) briefly moves the parent account
// back to a non-terminal "Accepted" provisioning state. Anything touching the account
// concurrently fails with AccountProvisioningStateInvalid, so the account mutations below
// are deliberately serialized rather than left to run in parallel. The capability hosts
// live in modules/foundry-caphost.bicep because they must be created only after the project
// identity holds data-plane roles on Cosmos, Storage and AI Search.
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
  dependsOn: [cosmosConnection, storageConnection, searchConnection]
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
  dependsOn: [embeddingDeployment]
}

output accountName string = account.name
output accountId string = account.id
output endpoint string = account.properties.endpoint
output openAiEndpoint string = 'https://${accountName}.openai.azure.com/'
@description('Project-scoped endpoint. The conversations API (BYO Cosmos DB thread storage) is only served here, not off the account endpoint above.')
output foundryProjectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output documentIntelligenceEndpoint string = 'https://${accountName}.cognitiveservices.azure.com/'
output projectName string = project.name
output projectPrincipalId string = project.identity.principalId
output accountPrincipalId string = account.identity.principalId
output chatDeploymentName string = chatDeployment.name
output embeddingDeploymentName string = embeddingDeployment.name
output cosmosConnectionName string = cosmosAccountName
output storageConnectionName string = storageAccountName
output searchConnectionName string = searchServiceName

