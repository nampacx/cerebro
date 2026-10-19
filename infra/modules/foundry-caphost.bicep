@description('Foundry Agents capability hosts. Kept in a separate module because they must be created only after the project managed identity holds data-plane roles on the bring-your-own Cosmos DB, Storage and AI Search resources, and after the account has settled from the model deployments.')
param accountName string
param projectName string
@description('Name of the project connection to the Cosmos DB account used for agent thread storage.')
param cosmosConnectionName string
@description('Name of the project connection to the Storage account used for agent file storage.')
param storageConnectionName string
@description('Name of the project connection to the Azure AI Search service used for the agent vector store.')
param searchConnectionName string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

// The resource provider silently registers the account-level Agents capability host
// internally as '{accountName}@aml_aiagentservice' regardless of the name requested here
// (confirmed by listing capabilityHosts on the account - GET by this requested name 404s even
// once the host is fully provisioned and working). That internal name isn't usable as a client-
// supplied name ("@" fails ARM's own name validation: only alphanumeric/dash/underscore), so it
// can't be matched from here - if this create ever again fails with "already exists...for the
// same ClientId", delete the account's actual capability host by its true internal name first
// (see the note in CLAUDE.md's gotchas), then retry.
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = {
  parent: account
  name: '${accountName}-caphost'
  properties: {
    capabilityHostKind: 'Agents'
  }
}

// The connection set below is atomic: the resource provider rejects a partial set with
// "Invalid connections configuration received. All connections must be provided, else
// omitted." vectorStoreConnections backs the agent runtime's own vector store, which is
// separate from this solution's pgvector retrieval but is still mandatory here.
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: '${projectName}-caphost'
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    #disable-next-line BCP037
    threadStorageConnections: [cosmosConnectionName]
    storageConnections: [storageConnectionName]
    #disable-next-line BCP037
    vectorStoreConnections: [searchConnectionName]
  }
  dependsOn: [accountCapabilityHost]
}

output accountCapabilityHostName string = accountCapabilityHost.name
output projectCapabilityHostName string = projectCapabilityHost.name
