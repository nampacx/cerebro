@description('Azure App Configuration store with key-values and private endpoint.')
param location string
param appConfigName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param appConfigDnsZoneId string
param keyValues array = []
@description('Object id of the principal running the deployment. Because local auth is disabled, ARM writes key-values through the data-plane proxy using this identity, so it needs App Configuration Data Owner.')
param deployerPrincipalId string = ''
@allowed(['User', 'ServicePrincipal', 'Group'])
param deployerPrincipalType string = 'User'

var appConfigurationDataOwnerRoleId = '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'

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
    dataPlaneProxy: {
      // Local auth is disabled, so ARM must forward data-plane calls (the keyValues
      // resources below) using the caller's Entra identity instead of an access key.
      authenticationMode: 'Pass-through'
      // ARM runs outside the VNet; honouring private link here would make key-value
      // writes unreachable while publicNetworkAccess is Disabled.
      privateLinkDelegation: 'Disabled'
    }
  }
}

resource deployerDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(appConfig.id, deployerPrincipalId, appConfigurationDataOwnerRoleId)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', appConfigurationDataOwnerRoleId)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
  }
}

resource configKeyValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-05-01' = [
  for kv in keyValues: {
    parent: appConfig
    name: kv.name
    properties: {
      value: kv.value
    }
    dependsOn: [deployerDataOwner]
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
