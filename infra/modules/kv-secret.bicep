@description('Writes a secret to Key Vault.')
param keyVaultName string
param secretName string
@secure()
param secretValue string

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2026-02-01' = {
  parent: keyVault
  name: secretName
  properties: {
    value: secretValue
  }
}

output secretName string = secret.name
output secretUri string = secret.properties.secretUri
