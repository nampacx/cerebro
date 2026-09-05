#Requires -Version 7.0
<#
.SYNOPSIS
    azd preprovision hook: reopens public network access on the App Configuration store.

.DESCRIPTION
    ARM writes App Configuration key-values over the data plane, which it cannot reach through a
    private endpoint unless the deployment runs inside the VNet. The postprovision hook closes the
    store after each provision, so it has to be reopened before the next one.

    Doing this here rather than relying on the Bicep template alone avoids a race: a network rule
    change made *during* the deployment takes up to a minute to reach the data plane, so the
    key-value writes in the same deployment can still be rejected with Forbidden.

    Silently skipped on the first provision, when the store does not exist yet and is created with
    public access already enabled.
#>
$ErrorActionPreference = 'Stop'

$storeName = $env:APP_CONFIG_NAME
$resourceGroup = $env:AZURE_RESOURCE_GROUP

if ([string]::IsNullOrWhiteSpace($storeName) -or [string]::IsNullOrWhiteSpace($resourceGroup)) {
    Write-Host "App Configuration store not provisioned yet; nothing to reopen."
    return
}

az appconfig show --name $storeName --resource-group $resourceGroup --only-show-errors --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "App Configuration '$storeName' does not exist yet; nothing to reopen."
    return
}

Write-Host "Temporarily allowing public network access on App Configuration '$storeName' so ARM can write key-values..."
for ($attempt = 1; $attempt -le 5; $attempt++) {
    az appconfig update --name $storeName --resource-group $resourceGroup `
        --enable-public-network true --only-show-errors --output none
    if ($LASTEXITCODE -eq 0) {
        # The data plane picks up network rule changes asynchronously.
        Start-Sleep -Seconds 60
        return
    }
    if ($attempt -lt 5) {
        Write-Warning "Attempt $attempt failed; retrying in $($attempt * 5)s..."
        Start-Sleep -Seconds ($attempt * 5)
    }
}
throw "Failed to enable public network access on App Configuration '$storeName'."
