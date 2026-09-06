#Requires -Version 7.0
<#
.SYNOPSIS
    azd postprovision hook: closes public network access on the App Configuration store.

.DESCRIPTION
    ARM writes App Configuration key-values over the data plane. It cannot reach a store that
    is only exposed through a private endpoint unless the deployment runs inside the VNet, so
    the store is provisioned with public network access enabled and locked down here, after the
    key-values have been written. Local authentication is disabled the whole time, so the store
    never accepts anything but Entra credentials.

    Skipped when PUBLIC_NETWORK_ACCESS is Enabled, i.e. when the whole environment is
    intentionally reachable from the internet.
#>
$ErrorActionPreference = 'Stop'

$storeName = $env:APP_CONFIG_NAME
$resourceGroup = $env:AZURE_RESOURCE_GROUP

if ([string]::IsNullOrWhiteSpace($storeName) -or [string]::IsNullOrWhiteSpace($resourceGroup)) {
    Write-Warning "APP_CONFIG_NAME or AZURE_RESOURCE_GROUP is not set; leaving App Configuration network access unchanged."
    return
}

if ($env:PUBLIC_NETWORK_ACCESS -eq 'Enabled') {
    Write-Host "PUBLIC_NETWORK_ACCESS is Enabled; leaving App Configuration '$storeName' publicly reachable."
    return
}

Write-Host "Disabling public network access on App Configuration '$storeName'..."
# Retried because this runs at the tail of a long deployment, where transient
# management.azure.com timeouts are common and would otherwise leave the store open.
for ($attempt = 1; $attempt -le 5; $attempt++) {
    az appconfig update --name $storeName --resource-group $resourceGroup `
        --enable-public-network false --only-show-errors --output none
    if ($LASTEXITCODE -eq 0) {
        Write-Host "App Configuration '$storeName' is now reachable only through its private endpoint."
        return
    }
    if ($attempt -lt 5) {
        Write-Warning "Attempt $attempt failed; retrying in $($attempt * 5)s..."
        Start-Sleep -Seconds ($attempt * 5)
    }
}
throw "Failed to disable public network access on App Configuration '$storeName'. Re-run 'azd provision', or run: az appconfig update --name $storeName --resource-group $resourceGroup --enable-public-network false"
