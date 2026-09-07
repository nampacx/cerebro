@description('Elastic Premium Function App (.NET isolated) with VNet integration, system-assigned identity, and optional Entra ID Easy Auth.')
param location string
param planName string
param functionAppName string
param tags object = {}
param appIntegrationSubnetId string
param storageAccountName string
param appInsightsConnectionString string
param appConfigEndpoint string
param keyVaultUri string
@description('Entra app registration (client) ID used for Easy Auth and token validation. Leave empty to skip Easy Auth configuration.')
param authClientId string = ''
param additionalAppSettings object = {}
@description('Origins allowed to call the Function App (the Static Web App hostname).')
param allowedCorsOrigins array = []

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' existing = {
  name: storageAccountName
}

resource plan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 3
    reserved: false
  }
}

var baseAppSettings = [
  { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
  {
    name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
  { name: 'WEBSITE_CONTENTSHARE', value: toLower(functionAppName) }
  { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
  { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
  { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
  { name: 'AppConfig__Endpoint', value: appConfigEndpoint }
  { name: 'KeyVault__Uri', value: keyVaultUri }
  { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
]

var additionalSettingsArray = [
  for setting in items(additionalAppSettings): {
    name: setting.key
    value: setting.value
  }
]

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: appIntegrationSubnetId
    // Renamed from vnetRouteAllEnabled, removed in this API version.
    outboundVnetRouting: {
      applicationTraffic: true
    }
    siteConfig: {
      netFrameworkVersion: 'v10.0'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: allowedCorsOrigins
        supportCredentials: false
      }
      appSettings: concat(baseAppSettings, additionalSettingsArray)
    }
  }
}

resource authSettings 'Microsoft.Web/sites/config@2025-03-01' = if (!empty(authClientId)) {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${authClientId}'
            authClientId
          ]
          // Deliberately no defaultAuthorizationPolicy. Easy Auth's built-in checks answer 403
          // before the request ever reaches the host, and an empty allowlist is a policy no
          // caller satisfies. Authorization belongs to EntraTokenValidator and the row-level
          // security policies; A2A partners also arrive with tokens acquired by their own app
          // registrations, which a client-id allowlist here would reject.
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
  }
}

output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
