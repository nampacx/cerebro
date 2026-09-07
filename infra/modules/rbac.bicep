@description('RBAC role assignments for the function app managed identity and the Foundry project identity.')
param functionAppPrincipalId string
param storageAccountId string
param aiAccountId string
param keyVaultId string
param appConfigId string
@description('Foundry project system-assigned identity; needs data access to the BYO Cosmos DB and Storage accounts.')
param foundryProjectPrincipalId string = ''
param cosmosAccountId string = ''
@description('Resource id of the Azure AI Search service backing the Foundry agent vector store.')
param searchServiceId string = ''

var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  cognitiveServicesOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  appConfigurationDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
  cosmosDbOperator: '230815da-be43-4aae-9cb4-875f7bd000aa'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' existing = {
  name: last(split(storageAccountId, '/'))
}

resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: last(split(aiAccountId, '/'))
}

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: last(split(keyVaultId, '/'))
}

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-06-01' existing = {
  name: last(split(appConfigId, '/'))
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, functionAppPrincipalId, roles.storageBlobDataOwner)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataOwner)
  }
}

// The blob trigger keeps its receipts/poison messages in queues on the same account.
resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, functionAppPrincipalId, roles.storageQueueDataContributor)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageQueueDataContributor)
  }
}

// Conversation index table.
resource tableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, functionAppPrincipalId, roles.storageTableDataContributor)
  scope: storageAccount
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageTableDataContributor)
  }
}

resource openAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiAccountId, functionAppPrincipalId, roles.cognitiveServicesOpenAiUser)
  scope: aiAccount
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cognitiveServicesOpenAiUser)
  }
}

resource cognitiveServicesRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiAccountId, functionAppPrincipalId, roles.cognitiveServicesUser)
  scope: aiAccount
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cognitiveServicesUser)
  }
}

resource keyVaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVaultId, functionAppPrincipalId, roles.keyVaultSecretsUser)
  scope: keyVault
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
  }
}

resource appConfigRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfigId, functionAppPrincipalId, roles.appConfigurationDataReader)
  scope: appConfig
  properties: {
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.appConfigurationDataReader)
  }
}

// ---- Foundry project identity access to bring-your-own agent storage ----

var enableFoundryStorageRoles = !empty(foundryProjectPrincipalId) && !empty(cosmosAccountId)

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2026-03-15' existing = if (enableFoundryStorageRoles) {
  name: enableFoundryStorageRoles ? last(split(cosmosAccountId, '/')) : 'placeholder'
}

resource foundryStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(foundryProjectPrincipalId)) {
  name: guid(storageAccountId, foundryProjectPrincipalId, roles.storageBlobDataContributor)
  scope: storageAccount
  properties: {
    principalId: foundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
  }
}

resource foundryCosmosControlPlaneRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableFoundryStorageRoles) {
  name: guid(cosmosAccountId, foundryProjectPrincipalId, roles.cosmosDbOperator)
  scope: cosmosAccount
  properties: {
    principalId: foundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cosmosDbOperator)
  }
}

// Cosmos data-plane access uses the account-scoped built-in Data Contributor definition
// (00000000-...-0002) because local auth is disabled on the account.
resource foundryCosmosDataRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2026-03-15' = if (enableFoundryStorageRoles) {
  parent: cosmosAccount
  name: guid(cosmosAccountId, foundryProjectPrincipalId, 'cosmos-data-contributor')
  properties: {
    principalId: foundryProjectPrincipalId
    roleDefinitionId: '${cosmosAccountId}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmosAccountId
  }
}

// ---- Foundry project identity access to the agent vector store (AI Search) ----

var enableFoundrySearchRoles = !empty(foundryProjectPrincipalId) && !empty(searchServiceId)

resource searchService 'Microsoft.Search/searchServices@2025-05-01' existing = if (enableFoundrySearchRoles) {
  name: enableFoundrySearchRoles ? last(split(searchServiceId, '/')) : 'placeholder'
}

// Index data plane: the agent runtime reads and writes its own vector indexes.
resource foundrySearchIndexDataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableFoundrySearchRoles) {
  name: guid(searchServiceId, foundryProjectPrincipalId, roles.searchIndexDataContributor)
  scope: searchService
  properties: {
    principalId: foundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchIndexDataContributor)
  }
}

// Control plane: the agent runtime creates and deletes the indexes themselves.
resource foundrySearchServiceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableFoundrySearchRoles) {
  name: guid(searchServiceId, foundryProjectPrincipalId, roles.searchServiceContributor)
  scope: searchService
  properties: {
    principalId: foundryProjectPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.searchServiceContributor)
  }
}
