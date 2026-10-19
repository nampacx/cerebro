@description('RBAC role assignments for the function app managed identity.')
param functionAppPrincipalId string
param storageAccountId string
param aiAccountId string
param keyVaultId string
param appConfigId string

var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  cognitiveServicesOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  cognitiveServicesUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  appConfigurationDataReader: '516239f1-63e1-4d78-a4de-a74fb236a071'
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
