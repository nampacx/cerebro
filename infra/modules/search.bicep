@description('Azure AI Search service backing the Foundry agent vector store, with private endpoint. Application retrieval is served by pgvector; this service exists because the Agents capability host requires a vectorStoreConnections entry alongside thread and file storage.')
param location string
param searchServiceName string
param tags object = {}
@description('Basic is sufficient because the agent runtime is the only consumer; raise to standard if agents make heavy use of the built-in vector store.')
@allowed(['basic', 'standard'])
param sku string = 'basic'
@description('Entra-only access. The Foundry connection uses authType "AAD" and the project identity holds the Search data-plane roles, so API keys are not needed. The official Foundry sample instead leaves local auth on ("aadOrApiKey"); set this to false if the agent runtime turns out to require key access.')
param disableLocalAuth bool = true
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param searchDnsZoneId string

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchServiceName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'disabled'
    disableLocalAuth: disableLocalAuth
    authOptions: disableLocalAuth ? null : { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    publicNetworkAccess: toLower(publicNetworkAccess)
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${searchServiceName}'
  params: {
    location: location
    name: 'pe-${searchServiceName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: search.id
    groupId: 'searchService'
    dnsZoneIds: [searchDnsZoneId]
    tags: tags
  }
}

output searchServiceName string = search.name
output searchServiceId string = search.id
output searchEndpoint string = 'https://${search.name}.search.windows.net'
