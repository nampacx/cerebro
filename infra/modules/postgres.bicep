@description('Azure Database for PostgreSQL Flexible Server with pgvector and Entra auth. Public network access is open; native PostgreSQL row-level security, not network isolation, is the access-control boundary.')
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

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
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
      publicNetworkAccess: 'Enabled'
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

// Public network access alone only opens the listener - PostgreSQL Flexible Server still
// drops every connection without a matching firewall rule. There's no VNet integration in
// this stack for the function app to reach the server through instead, so without this rule
// its outbound calls (from the platform's shared, unpredictable outbound IPs) are dropped
// outright. This specific start/end IP pair is Azure's documented sentinel for "allow public
// access from any Azure service within Azure to this server" - it is not a literal 0.0.0.0/0.
resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2025-08-01' = {
  parent: server
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = {
  parent: server
  name: entraAdminObjectId
  properties: {
    principalName: entraAdminPrincipalName
    principalType: entraAdminPrincipalType
    tenantId: tenant().tenantId
  }
}

resource allowedExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'VECTOR,UUID-OSSP'
    source: 'user-override'
  }
  dependsOn: [entraAdmin]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

output serverName string = server.name
output serverFqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
