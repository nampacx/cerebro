@description('Serverless Cosmos DB (NoSQL) account used as customer-managed thread storage for Microsoft Foundry conversations.')
param location string
param accountName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param cosmosDnsZoneId string
@description('Resource IDs allowed to bypass the IP/VNet firewall. Not currently used for the Foundry account: Cosmos DB\'s networkAclBypassResourceIds only accepts Synapse Link / Data Factory / Azure ML workspace resource ids, not Cognitive Services accounts (see ai.bicep\'s networkInjections for how Foundry actually reaches this account). Kept as a passthrough for a future Synapse Link scenario.')
param networkAclBypassResourceIds array = []

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
// *any* private endpoint is approved on the account - confirmed live, it rejected Foundry's
// calls even with publicNetworkAccess=Enabled and no IP/VNet rules, because those calls
// originated outside this VNet. Now that ai.bicep injects the Foundry account's agent client
// into snet-agent, its calls to this account arrive from inside the VNet and resolve through
// the private endpoint correctly, so publicNetworkAccess=Disabled (the private-only path) is
// the fully-supported configuration; Enabled (no PE) remains for environments not using the
// agent subnet.
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
