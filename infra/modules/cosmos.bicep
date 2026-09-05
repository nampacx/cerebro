@description('Serverless Cosmos DB (NoSQL) account used as customer-managed thread storage for Microsoft Foundry conversations.')
param location string
param accountName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param cosmosDnsZoneId string

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    databaseAccountOfferType: 'Standard'
    minimalTlsVersion: 'Tls12'
    disableLocalAuth: true
    publicNetworkAccess: publicNetworkAccess
    networkAclBypass: 'AzureServices'
    capabilities: [
      { name: 'EnableServerless' }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${accountName}'
  params: {
    location: location
    name: 'pe-${accountName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: account.id
    groupId: 'Sql'
    dnsZoneIds: [cosmosDnsZoneId]
    tags: tags
  }
}

output accountName string = account.name
output accountId string = account.id
output documentEndpoint string = account.properties.documentEndpoint
