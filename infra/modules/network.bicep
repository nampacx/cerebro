@description('Virtual network with subnets for function integration and private endpoints, plus private DNS zones.')
param location string
param vnetName string
param tags object = {}

var privateDnsZoneNames = [
  'privatelink.postgres.database.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.vaultcore.azure.net'
  'privatelink.azconfig.io'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.table.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.search.windows.net'
  // The Elastic Premium plan mounts its content share (WEBSITE_CONTENTSHARE) over the VNet,
  // so Azure Files needs a private endpoint too.
  'privatelink.file.${environment().suffixes.storage}'
]

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.20.0.0/16']
    }
    subnets: [
      {
        name: 'snet-app-integration'
        properties: {
          addressPrefix: '10.20.1.0/24'
          delegations: [
            {
              name: 'webapp-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.20.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Delegated so the Foundry Agents capability host can inject its agent client here;
        // this is what lets outbound calls to the BYO Cosmos/Storage/Search connections stay
        // on the VNet instead of leaving over the public internet. Sized /24 per Microsoft's
        // guidance for the Microsoft.App/environments delegation.
        name: 'snet-agent'
        properties: {
          addressPrefix: '10.20.3.0/24'
          delegations: [
            {
              name: 'agent-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// Registered API versions for this type top out at 2024-06-01, unlike virtualNetworks above.
resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for zoneName in privateDnsZoneNames: {
    name: zoneName
    location: 'global'
    tags: tags
  }
]

resource vnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (zoneName, i) in privateDnsZoneNames: {
    parent: privateDnsZones[i]
    name: 'link-${vnetName}'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }
]

output vnetId string = vnet.id
output appIntegrationSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
output agentSubnetId string = vnet.properties.subnets[2].id
output postgresDnsZoneId string = privateDnsZones[0].id
output blobDnsZoneId string = privateDnsZones[1].id
output keyVaultDnsZoneId string = privateDnsZones[2].id
output appConfigDnsZoneId string = privateDnsZones[3].id
output cognitiveServicesDnsZoneId string = privateDnsZones[4].id
output openAiDnsZoneId string = privateDnsZones[5].id
output aiServicesDnsZoneId string = privateDnsZones[6].id
output tableDnsZoneId string = privateDnsZones[7].id
output queueDnsZoneId string = privateDnsZones[8].id
output cosmosDnsZoneId string = privateDnsZones[9].id
output searchDnsZoneId string = privateDnsZones[10].id
output fileDnsZoneId string = privateDnsZones[11].id
