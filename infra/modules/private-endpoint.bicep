@description('Generic private endpoint with DNS zone group.')
param location string
param name string
param subnetId string
param targetResourceId string
param groupId string
param dnsZoneIds array
param tags object = {}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      for (zoneId, i) in dnsZoneIds: {
        name: 'config-${i}'
        properties: {
          privateDnsZoneId: zoneId
        }
      }
    ]
  }
}

output privateEndpointId string = privateEndpoint.id
