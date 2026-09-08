targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment.')
param environmentName string

@minLength(1)
@description('Primary location for all resources. swedencentral is the default because PostgreSQL Flexible Server capacity is constrained in many other regions.')
param location string = 'swedencentral'

@description('Entra app registration (client) ID used for API authorization. Leave empty to skip Easy Auth wiring (code-level JWT validation still requires it at runtime).')
param authClientId string = ''

@description('Object ID of the Entra principal to set as PostgreSQL Entra administrator (e.g. the deploying user).')
param postgresEntraAdminObjectId string

@description('UPN or display name of the PostgreSQL Entra administrator principal.')
param postgresEntraAdminPrincipalName string

@allowed(['User', 'ServicePrincipal', 'Group'])
param postgresEntraAdminPrincipalType string = 'User'

@secure()
@description('Optional override for the PostgreSQL local admin password. Leave empty (default) to have the deployment generate a strong random password. Either way it is stored in Key Vault as "postgres-admin-password"; the app itself authenticates with its Entra managed identity.')
param postgresAdminPassword string = ''

@secure()
@description('Random seed used to derive the generated PostgreSQL admin password. Do not set this manually - the default produces a new GUID per deployment.')
param postgresAdminPasswordSeed string = newGuid()

@description('Enabled for dev/test scenarios; Disabled for enterprise/production private-only access.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Disabled'

param chatModelDeploymentName string = 'gpt-5'
param chatModelName string = 'gpt-5'
param chatModelVersion string = ''
param embeddingModelDeploymentName string = 'text-embedding-3-large'
param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
@description('Embedding vector dimensions; must match db/schema.sql vector(N).')
param embeddingDimensions int = 1536

@description('Attach customer-managed Cosmos DB + Storage + AI Search to Foundry so agent conversations are stored in your own subscription. Set to "false" if the capability host API rejects the configuration in your region.')
@allowed(['true', 'false'])
param useCustomFoundryStorage string = 'true'

@description('SKU of the Azure AI Search service backing the Foundry agent vector store. The Agents capability host requires an AI Search connection even though this solution serves retrieval from pgvector, so basic is the default.')
@allowed(['basic', 'standard'])
param searchSku string = 'basic'

@description('Region for the Static Web App. Static Web Apps is available in a limited set of regions; westeurope is the closest to swedencentral.')
param staticWebAppLocation string = 'westeurope'

@secure()
@description('Client secret of the Entra app registration used by Static Web Apps built-in Entra authentication. Leave empty to configure it manually after deployment.')
param authClientSecret string = ''

var tags = { 'azd-env-name': environmentName }
var resourceToken = toLower(uniqueString(subscription().id, environmentName))
var functionAppName = 'func-${resourceToken}'
var functionAppUrl = 'https://${functionAppName}.azurewebsites.net'

// Strong password derived from a per-deployment GUID: upper + lower + digits + symbol,
// 25 characters. Only used for the local `pgadmin` login, which is never used by the
// application (it connects with its managed identity) - the value is kept in Key Vault
// for break-glass access.
var generatedPostgresAdminPassword = 'Pg${toUpper(substring(uniqueString(postgresAdminPasswordSeed), 0, 7))}${uniqueString(subscription().id, environmentName, postgresAdminPasswordSeed)}#4z'
var effectivePostgresAdminPassword = empty(postgresAdminPassword) ? generatedPostgresAdminPassword : postgresAdminPassword

// Cosmos, Storage and AI Search are always deployed, so bring-your-own agent storage is
// governed solely by this switch. The capability hosts require all three connections.
var byoFoundryStorage = useCustomFoundryStorage == 'true'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    vnetName: 'vnet-${resourceToken}'
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    logAnalyticsName: 'log-${resourceToken}'
    appInsightsName: 'appi-${resourceToken}'
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    location: location
    storageAccountName: 'st${resourceToken}'
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    fileDnsZoneId: network.outputs.fileDnsZoneId
    contentShareName: toLower(functionAppName)
    tags: tags
  }
}

module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  scope: rg
  params: {
    location: location
    accountName: 'cosmos-${resourceToken}'
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    cosmosDnsZoneId: network.outputs.cosmosDnsZoneId
    // Reverted to always-empty: Cosmos DB's networkAclBypassResourceIds only supports
    // Synapse Link / Data Factory / Azure ML workspace resource ids, not Cognitive
    // Services/Foundry accounts, so passing foundryAccountResourceId here fails
    // provisioning with "Invalid supplied NetworkAclBypassResourceId". The
    // Foundry-Agents-to-Cosmos firewall bypass this was meant to provide still needs a
    // different mechanism.
    networkAclBypassResourceIds: []
    tags: tags
  }
}

module search 'modules/search.bicep' = {
  name: 'search'
  scope: rg
  params: {
    location: location
    searchServiceName: 'srch-${resourceToken}'
    sku: searchSku
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    searchDnsZoneId: network.outputs.searchDnsZoneId
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  scope: rg
  params: {
    location: location
    keyVaultName: 'kv-${resourceToken}'
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    keyVaultDnsZoneId: network.outputs.keyVaultDnsZoneId
    tags: tags
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  scope: rg
  params: {
    location: location
    serverName: 'psql-${resourceToken}'
    administratorPassword: effectivePostgresAdminPassword
    entraAdminObjectId: postgresEntraAdminObjectId
    entraAdminPrincipalName: postgresEntraAdminPrincipalName
    entraAdminPrincipalType: postgresEntraAdminPrincipalType
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    postgresDnsZoneId: network.outputs.postgresDnsZoneId
    tags: tags
  }
}

module ai 'modules/ai.bicep' = {
  name: 'ai'
  scope: rg
  params: {
    location: location
    accountName: 'aif-${resourceToken}'
    projectName: 'cerebro-project'
    publicNetworkAccess: publicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    agentSubnetId: network.outputs.agentSubnetId
    cognitiveServicesDnsZoneId: network.outputs.cognitiveServicesDnsZoneId
    openAiDnsZoneId: network.outputs.openAiDnsZoneId
    aiServicesDnsZoneId: network.outputs.aiServicesDnsZoneId
    chatModelDeploymentName: chatModelDeploymentName
    chatModelName: chatModelName
    chatModelVersion: chatModelVersion
    embeddingModelDeploymentName: embeddingModelDeploymentName
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    useCustomFoundryStorage: byoFoundryStorage
    cosmosAccountId: cosmos.outputs.accountId
    storageAccountId: storage.outputs.storageAccountId
    searchServiceId: search.outputs.searchServiceId
    tags: tags
  }
}

@description('Public network access for the App Configuration store *during provisioning*. ARM writes key-values over the data plane, which it cannot reach through a private endpoint unless the deployment runs inside the VNet, so this defaults to Enabled and the azd postprovision hook closes it again. Local auth stays disabled, so Entra RBAC is enforced the whole time.')
@allowed(['Enabled', 'Disabled'])
param appConfigPublicNetworkAccess string = 'Enabled'

module appConfig 'modules/appconfig.bicep' = {
  name: 'appconfig'
  scope: rg
  params: {
    location: location
    appConfigName: 'appcs-${resourceToken}'
    publicNetworkAccess: appConfigPublicNetworkAccess
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    appConfigDnsZoneId: network.outputs.appConfigDnsZoneId
    deployerPrincipalId: postgresEntraAdminObjectId
    deployerPrincipalType: postgresEntraAdminPrincipalType
    tags: tags
    keyValues: [
      { name: 'Rag:OpenAiEndpoint', value: ai.outputs.openAiEndpoint }
      { name: 'Rag:FoundryProjectEndpoint', value: ai.outputs.foundryProjectEndpoint }
      { name: 'Rag:DocumentIntelligenceEndpoint', value: ai.outputs.documentIntelligenceEndpoint }
      { name: 'Rag:ChatDeployment', value: chatModelDeploymentName }
      { name: 'Rag:EmbeddingDeployment', value: embeddingModelDeploymentName }
      { name: 'Rag:EmbeddingDimensions', value: string(embeddingDimensions) }
      { name: 'Rag:PostgresHost', value: postgres.outputs.serverFqdn }
      { name: 'Rag:PostgresDatabase', value: postgres.outputs.databaseName }
      { name: 'Rag:BlobEndpoint', value: storage.outputs.blobEndpoint }
      { name: 'Rag:QueueEndpoint', value: storage.outputs.queueEndpoint }
      { name: 'Rag:DocumentsContainer', value: storage.outputs.documentsContainerName }
      { name: 'Rag:DocumentProcessingQueue', value: storage.outputs.documentProcessingQueueName }
      { name: 'Rag:ChunkSizeTokens', value: '512' }
      { name: 'Rag:ChunkOverlapTokens', value: '64' }
    ]
  }
}

module staticWebApp 'modules/staticwebapp.bicep' = {
  name: 'staticwebapp'
  scope: rg
  params: {
    location: staticWebAppLocation
    name: 'swa-${resourceToken}'
    apiBaseUrl: functionAppUrl
    authClientId: authClientId
    authClientSecret: authClientSecret
    tags: union(tags, { 'azd-service-name': 'web' })
  }
}

module functionApp 'modules/function.bicep' = {
  name: 'function'
  scope: rg
  params: {
    location: location
    planName: 'plan-${resourceToken}'
    functionAppName: functionAppName
    appIntegrationSubnetId: network.outputs.appIntegrationSubnetId
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    appConfigEndpoint: appConfig.outputs.appConfigEndpoint
    keyVaultUri: keyVault.outputs.keyVaultUri
    authClientId: authClientId
    allowedCorsOrigins: [staticWebApp.outputs.staticWebAppUrl]
    additionalAppSettings: {
      Auth__TenantId: tenant().tenantId
      Auth__ClientId: authClientId
    }
    tags: union(tags, { 'azd-service-name': 'api' })
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  scope: rg
  params: {
    functionAppPrincipalId: functionApp.outputs.functionAppPrincipalId
    storageAccountId: storage.outputs.storageAccountId
    aiAccountId: ai.outputs.accountId
    keyVaultId: keyVault.outputs.keyVaultId
    appConfigId: appConfig.outputs.appConfigId
    foundryProjectPrincipalId: ai.outputs.projectPrincipalId
    cosmosAccountId: cosmos.outputs.accountId
    searchServiceId: search.outputs.searchServiceId
  }
}

// Created last: the capability hosts need the project identity to already hold data-plane
// roles on Cosmos, Storage and AI Search, and need the Foundry account to be settled after
// the model deployments.
module foundryCapabilityHosts 'modules/foundry-caphost.bicep' = if (byoFoundryStorage) {
  name: 'foundry-caphost'
  scope: rg
  params: {
    accountName: ai.outputs.accountName
    projectName: ai.outputs.projectName
    cosmosConnectionName: ai.outputs.cosmosConnectionName
    storageConnectionName: ai.outputs.storageConnectionName
    searchConnectionName: ai.outputs.searchConnectionName
    agentSubnetId: network.outputs.agentSubnetId
  }
  dependsOn: [rbac]
}

module pgPasswordSecret 'modules/kv-secret.bicep' = {
  name: 'pg-password-secret'
  scope: rg
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    secretName: 'postgres-admin-password'
    secretValue: effectivePostgresAdminPassword
  }
}

// Consumed by src/web/scripts/generate-config.mjs to stamp the tenant-specific
// `openIdIssuer` into staticwebapp.config.json. Without it the generator has no
// tenant id and Static Web Apps sign-in loops. azd exports outputs as env vars.
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output FUNCTION_APP_URL string = 'https://${functionApp.outputs.functionAppHostName}'
output FUNCTION_APP_PRINCIPAL_ID string = functionApp.outputs.functionAppPrincipalId
output POSTGRES_SERVER_NAME string = postgres.outputs.serverName
output POSTGRES_FQDN string = postgres.outputs.serverFqdn
output POSTGRES_DATABASE string = postgres.outputs.databaseName
output APP_CONFIG_ENDPOINT string = appConfig.outputs.appConfigEndpoint
output APP_CONFIG_NAME string = appConfig.outputs.appConfigName
output KEY_VAULT_URI string = keyVault.outputs.keyVaultUri
output POSTGRES_ADMIN_SECRET_NAME string = pgPasswordSecret.outputs.secretName
output AI_FOUNDRY_ENDPOINT string = ai.outputs.endpoint
output OPENAI_ENDPOINT string = ai.outputs.openAiEndpoint
output DOCUMENT_INTELLIGENCE_ENDPOINT string = ai.outputs.documentIntelligenceEndpoint
output STORAGE_BLOB_ENDPOINT string = storage.outputs.blobEndpoint
output COSMOS_ACCOUNT_NAME string = cosmos.outputs.accountName
output COSMOS_ENDPOINT string = cosmos.outputs.documentEndpoint
output STATIC_WEB_APP_NAME string = staticWebApp.outputs.staticWebAppName
output STATIC_WEB_APP_URL string = staticWebApp.outputs.staticWebAppUrl
output WEB_API_BASE_URL string = functionAppUrl
