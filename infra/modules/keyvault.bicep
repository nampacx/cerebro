@description('Key Vault with RBAC authorization and private endpoint.')
param location string
param keyVaultName string
param tags object = {}
param publicNetworkAccess string = 'Disabled'
param privateEndpointSubnetId string
param keyVaultDnsZoneId string

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
      bypass: 'AzureServices'
    }
  }
}

module privateEndpoint 'private-endpoint.bicep' = {
  name: 'pe-${keyVaultName}'
  params: {
    location: location
    name: 'pe-${keyVaultName}'
    subnetId: privateEndpointSubnetId
    targetResourceId: keyVault.id
    groupId: 'vault'
    dnsZoneIds: [keyVaultDnsZoneId]
    tags: tags
  }
}

output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultId string = keyVault.id
