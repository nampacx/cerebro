@description('Azure Database for PostgreSQL Flexible Server with pgvector, Entra auth, and private endpoint.')
param location string
param serverName string
param tags object = {}
param administratorLogin string = 'pgadmin'
@secure()
param administratorPassword string
param entraAdminObjectId string
param entraAdminPrincipalName string
@allowed(['User', 'ServicePrincipal', 'Group'])
param entraAdminPrincipalType string = 'User'
param databaseName string = 'ragdb'
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param postgresDnsZoneId string

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: 'Standard_D2ds_v5'
    tier: 'GeneralPurpose'
  }
  properties: {
    version: '16'
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: {
      storageSizeGB: 64
      autoGrow: 'Enabled'
    }
    network: {
      publicNetworkAccess: publicNetworkAccess
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: server
  name: entraAdminObjectId
  properties: {
    principalName: entraAdminPrincipalName
    principalType: entraAdminPrincipalType
    tenantId: tenant().tenantId
  }
}

resource allowedExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'VECTOR,UUID-OSSP'
    source: 'user-override'
  }
  dependsOn: [entraAdmin]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${serverName}'
  params: {
    location: location
    name: 'pe-${serverName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: server.id
    groupId: 'postgresqlServer'
    dnsZoneIds: [postgresDnsZoneId]
    tags: tags
  }
}

output serverName string = server.name
output serverFqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
