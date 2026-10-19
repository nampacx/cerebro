@description('Microsoft Foundry (AI Services) account with project and chat + embedding deployments. Document Intelligence is included in the AIServices multi-service account.')
param location string
param accountName string
param projectName string
param tags object = {}

param chatModelDeploymentName string = 'gpt-5'
param chatModelName string = 'gpt-5'
param chatModelVersion string = ''
param chatModelCapacity int = 50
param embeddingModelDeploymentName string = 'text-embedding-3-large'
param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
param embeddingModelCapacity int = 120

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
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
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

// Every child write (model deployments) briefly moves the parent account back to a
// non-terminal "Accepted" provisioning state. Anything touching the account concurrently
// fails with AccountProvisioningStateInvalid, so the deployments below are deliberately
// serialized rather than left to run in parallel.
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

output accountName string = account.name
output accountId string = account.id
output endpoint string = account.properties.endpoint
output openAiEndpoint string = 'https://${accountName}.openai.azure.com/'
@description('Project-scoped endpoint. The conversations API (Microsoft-managed thread storage) is only served here, not off the account endpoint above.')
output foundryProjectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output documentIntelligenceEndpoint string = 'https://${accountName}.cognitiveservices.azure.com/'
output projectName string = project.name
output chatDeploymentName string = chatDeployment.name
output embeddingDeploymentName string = embeddingDeployment.name

