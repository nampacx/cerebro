@description('Azure App Configuration store with key-values and private endpoint.')
param location string
param appConfigName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param appConfigDnsZoneId string
param keyValues array = []

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: appConfigName
  location: location
  tags: tags
  sku: {
    name: 'standard'
  }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: publicNetworkAccess
  }
}

resource configKeyValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-05-01' = [
  for kv in keyValues: {
    parent: appConfig
    name: kv.name
    properties: {
      value: kv.value
    }
  }
]

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${appConfigName}'
  params: {
    location: location
    name: 'pe-${appConfigName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: appConfig.id
    groupId: 'configurationStores'
    dnsZoneIds: [appConfigDnsZoneId]
    tags: tags
  }
}

output appConfigName string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint
output appConfigId string = appConfig.id
