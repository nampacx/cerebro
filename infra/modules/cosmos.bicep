@description('Serverless Cosmos DB (NoSQL) account used as customer-managed thread storage for Microsoft Foundry conversations.')
param location string
param accountName string
param tags object = {}

resource account 'Microsoft.DocumentDB/databaseAccounts@2026-03-15' = {
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
    publicNetworkAccess: 'Enabled'
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

output accountName string = account.name
output accountId string = account.id
output documentEndpoint string = account.properties.documentEndpoint
