@description('Serverless Cosmos DB (NoSQL) account used as customer-managed thread storage for Microsoft Foundry conversations.')
param location string
param accountName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param cosmosDnsZoneId string
@description('Resource IDs (e.g. the Foundry account) allowed to bypass the IP/VNet firewall. Foundry\'s Agents runtime calls Cosmos from outside this VNet even for BYO thread storage, so it needs an explicit exception rather than broader public access.')
param networkAclBypassResourceIds array = []

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
    networkAclBypassResourceIds: networkAclBypassResourceIds
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

// Conditional, unlike the other modules' private endpoints: Cosmos DB's newer "thin client"
// data-plane protocol enforces its network rules more strictly than the classic gateway once
// *any* private endpoint is approved on the account, blocking Foundry's own (out-of-VNet) calls
// to this account's BYO thread storage even with publicNetworkAccess=Enabled and no IP/VNet
// rules. There is no resource-instance bypass for Foundry accounts (networkAclBypassResourceIds
// is Synapse-Link-only), so when Foundry's conversations API needs to reach this account, the
// private endpoint has to stay off - confirmed by removing it against the live account.
module privateEndpoint 'private-endpoint.bicep' = if (publicNetworkAccess == 'Disabled') {
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
