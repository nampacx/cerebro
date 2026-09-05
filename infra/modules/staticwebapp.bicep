@description('Azure Static Web App (Standard) hosting the React/Vite example client with Entra ID built-in authentication.')
param location string
param name string
param tags object = {}
@description('Function App base URL the SPA calls for the RAG API.')
param apiBaseUrl string
@description('Entra app registration (client) ID used by the Static Web Apps custom Entra provider.')
param authClientId string = ''
@description('Name of the Key Vault secret / app setting holding the Entra client secret used by the SWA auth provider.')
@secure()
param authClientSecret string = ''

// Static Web Apps requires a paired region set; Standard SKU is needed for custom
// authentication providers (built-in Entra ID with a specific tenant + audience).
resource staticWebApp 'Microsoft.Web/staticSites@2024-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    provider: 'Custom'
  }
}

resource appSettings 'Microsoft.Web/staticSites/config@2024-04-01' = {
  parent: staticWebApp
  name: 'appsettings'
  properties: union(
    {
      API_BASE_URL: apiBaseUrl
      AZURE_TENANT_ID: tenant().tenantId
      AZURE_CLIENT_ID: authClientId
    },
    empty(authClientSecret) ? {} : { AZURE_CLIENT_SECRET: authClientSecret }
  )
}

output staticWebAppName string = staticWebApp.name
output staticWebAppHostName string = staticWebApp.properties.defaultHostname
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
