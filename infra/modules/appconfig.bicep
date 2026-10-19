@description('Azure App Configuration store with key-values.')
param location string
param appConfigName string
param tags object = {}
param keyValues array = []
@description('Object id of the principal running the deployment. Because local auth is disabled, ARM writes key-values through the data-plane proxy using this identity, so it needs App Configuration Data Owner.')
param deployerPrincipalId string = ''
@allowed(['User', 'ServicePrincipal', 'Group'])
param deployerPrincipalType string = 'User'

var appConfigurationDataOwnerRoleId = '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-06-01' = {
  name: appConfigName
  location: location
  tags: tags
  sku: {
    name: 'standard'
  }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    dataPlaneProxy: {
      // Local auth is disabled, so ARM must forward data-plane calls (the keyValues
      // resources below) using the caller's Entra identity instead of an access key.
      authenticationMode: 'Pass-through'
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

resource configKeyValues 'Microsoft.AppConfiguration/configurationStores/keyValues@2024-06-01' = [
  for kv in keyValues: {
    parent: appConfig
    name: kv.name
    properties: {
      value: kv.value
    }
    dependsOn: [deployerDataOwner]
  }
]

output appConfigName string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint
output appConfigId string = appConfig.id
