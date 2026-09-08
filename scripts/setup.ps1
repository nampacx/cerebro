<#
.SYNOPSIS
One-shot setup for Cerebro: Entra ID app registration + azd environment
configuration + provisioning, deployment, and database schema.

What it does, in order:
  1. Verifies prerequisites (az, azd) and that you are signed in to both.
  2. Creates or selects the azd environment.
  3. Creates/updates the Entra ID app registration (API scope, groups claim,
     redirect URIs, client secret) and writes AUTH_CLIENT_ID / AUTH_CLIENT_SECRET
     into the azd environment.
  4. Sets the remaining azd environment values (PostgreSQL Entra admin, network
     access, location). The PostgreSQL admin password is *not* set here - it is
     generated inside Bicep and stored in Key Vault.
  5. Runs `azd up` (provision + deploy).
  6. Re-runs the app registration step with the deployed Static Web App hostname
     and redeploys the web client so its config picks up the final values.
  7. Applies the database schema and the managed-identity role. When the server's
     public network access is Disabled, it is temporarily enabled first (with a
     firewall rule scoped to this machine) and restored to Disabled afterwards -
     see Initialize-Database below. Skip with -SkipDatabaseInit.

Pass -DatabaseOnly to skip steps 2-6 entirely and just (re-)apply the database
schema against an already-provisioned environment - e.g. after editing
db/schema.sql. This still does the temporary network open/close in step 7.

.EXAMPLE
./scripts/setup.ps1 -EnvironmentName cerebro-dev

.EXAMPLE
# Dev/test with public network access left open permanently.
./scripts/setup.ps1 -EnvironmentName cerebro-dev -PublicNetworkAccess Enabled

.EXAMPLE
# Only refresh the app registration and azd settings, skip deployment and the database.
./scripts/setup.ps1 -EnvironmentName cerebro-dev -SkipDeploy

.EXAMPLE
# Re-apply db/schema.sql against an existing deployment without touching infra or app code.
./scripts/setup.ps1 -EnvironmentName cerebro-dev -DatabaseOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EnvironmentName,
    [string] $Location = 'swedencentral',
    [string] $StaticWebAppLocation = 'westeurope',
    [string] $AppRegistrationDisplayName,
    [string] $SubscriptionId,
    [ValidateSet('Enabled', 'Disabled')] [string] $PublicNetworkAccess = 'Disabled',
    [ValidateSet('true', 'false')] [string] $UseCustomFoundryStorage = 'true',
    [string] $LocalDevOrigin = 'http://localhost:5173',
    [switch] $SkipDatabaseInit,
    [switch] $SkipDeploy,
    [switch] $DatabaseOnly
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptRoot

if ($DatabaseOnly -and $SkipDeploy) { throw '-DatabaseOnly and -SkipDeploy are mutually exclusive.' }
if ($DatabaseOnly -and $SkipDatabaseInit) { throw '-DatabaseOnly and -SkipDatabaseInit are mutually exclusive.' }

if (-not $AppRegistrationDisplayName) { $AppRegistrationDisplayName = $EnvironmentName }

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Checked {
    param([scriptblock] $Command, [string] $What)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)." }
}

function Get-EntraAdminPrincipalName {
    # Mirrors the PostgreSQL Entra administrator detection below: the server authenticates
    # against the directory UPN, which differs from the Azure CLI account name for guest users,
    # and az ad signed-in-user has nothing to return in a service-principal context.
    $signedInUserJson = az ad signed-in-user show -o json 2>$null
    $signedInUser = if ($LASTEXITCODE -eq 0 -and $signedInUserJson) { $signedInUserJson | ConvertFrom-Json } else { $null }
    if ($signedInUser) {
        if ($signedInUser.userPrincipalName) { return $signedInUser.userPrincipalName }
        return $signedInUser.displayName
    }
    $spAppId = az account show --query 'user.name' -o tsv
    $sp = az ad sp show --id $spAppId -o json | ConvertFrom-Json
    return $sp.displayName
}

function Set-PostgresPublicAccess {
    param([string] $ServerName, [string] $ResourceGroup, [string] $Access)
    # Retried because this can run at the tail of a long deployment, where transient
    # management.azure.com timeouts are common.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        az postgres flexible-server update --name $ServerName --resource-group $ResourceGroup `
            --public-access $Access --only-show-errors --output none
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -lt 5) {
            Write-Warning "Attempt $attempt to set PostgreSQL public access to '$Access' failed; retrying in $($attempt * 5)s..."
            Start-Sleep -Seconds ($attempt * 5)
        }
    }
    throw "Failed to set PostgreSQL public access to '$Access' for '$ServerName'. Re-run, or: az postgres flexible-server update --name $ServerName --resource-group $ResourceGroup --public-access $Access"
}

function Initialize-Database {
    <#
    Applies db/schema.sql and the managed-identity role via setup-database.ps1. The live
    server's current network state - not the -PublicNetworkAccess parameter or the azd
    environment's stored value - decides whether a temporary opening is needed, so this works
    correctly however the server got into its current state (fresh -PublicNetworkAccess Disabled
    deploy, -DatabaseOnly against an older environment, a server someone already opened by hand).
    Restores the prior state in a finally block, so a failed schema step does not leave the
    database publicly reachable.
    #>
    param(
        [string] $ServerName,
        [string] $Database,
        [string] $FunctionAppName,
        [string] $ResourceGroup,
        [string] $AdminUser
    )

    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
        Write-Warning "'psql' was not found on PATH; skipping database initialization. Run scripts/setup-database.ps1 manually."
        return
    }

    $currentAccess = az postgres flexible-server show --name $ServerName --resource-group $ResourceGroup `
        --query 'network.publicNetworkAccess' -o tsv
    $reopened = $false

    if ($currentAccess -ne 'Enabled') {
        Write-Step "Temporarily enabling public network access on PostgreSQL server '$ServerName'"
        Set-PostgresPublicAccess -ServerName $ServerName -ResourceGroup $ResourceGroup -Access 'Enabled'
        # The control-plane change needs a short window before the data-plane firewall honors
        # it. setup-database.ps1 retries its own connection attempts, but starting that loop
        # immediately would burn attempts against a server that has not caught up yet.
        Start-Sleep -Seconds 30
        $reopened = $true
    }

    try {
        & "$scriptRoot/setup-database.ps1" `
            -ServerName $ServerName `
            -Database $Database `
            -FunctionAppName $FunctionAppName `
            -AdminUser $AdminUser `
            -ResourceGroup $ResourceGroup
    }
    finally {
        if ($reopened) {
            Write-Step 'Restoring PostgreSQL network access to Disabled'
            az postgres flexible-server firewall-rule delete `
                --resource-group $ResourceGroup --server-name $ServerName --name 'setup-client-ip' `
                --yes --only-show-errors --output none 2>$null
            Set-PostgresPublicAccess -ServerName $ServerName -ResourceGroup $ResourceGroup -Access 'Disabled'
        }
    }
}

# ---- 1. Prerequisites -------------------------------------------------------
Write-Step 'Checking prerequisites'
foreach ($tool in @('az', 'azd')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' was not found on PATH. Install it and re-run this script."
    }
}

$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in to Azure CLI. Run 'az login' first." }

if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Invoke-Checked { az account set --subscription $SubscriptionId } 'az account set'
    $account = az account show -o json | ConvertFrom-Json
}

Write-Host "  Subscription : $($account.name) ($($account.id))"
Write-Host "  Signed in as : $($account.user.name)"

# ---- 2. azd environment -----------------------------------------------------
Write-Step "Preparing azd environment '$EnvironmentName'"
Push-Location $repoRoot
try {
    $existingEnvsJson = azd env list -o json 2>$null
    $existingEnvs = if ($existingEnvsJson) { $existingEnvsJson | ConvertFrom-Json } else { @() }
    if ($existingEnvs | Where-Object { $_.Name -eq $EnvironmentName }) {
        Write-Host "  Reusing existing environment."
        Invoke-Checked { azd env select $EnvironmentName } 'azd env select'
    }
    elseif ($DatabaseOnly) {
        throw "azd environment '$EnvironmentName' does not exist. -DatabaseOnly requires an environment that has already been deployed with a full './scripts/setup.ps1 -EnvironmentName $EnvironmentName' run."
    }
    else {
        Invoke-Checked { azd env new $EnvironmentName --location $Location --subscription $account.id } 'azd env new'
    }

    if ($DatabaseOnly) {
        Write-Step "Applying database schema only (environment '$EnvironmentName')"
        $outputs = azd env get-values -o json | ConvertFrom-Json
        foreach ($required in @('POSTGRES_SERVER_NAME', 'POSTGRES_DATABASE', 'FUNCTION_APP_NAME', 'AZURE_RESOURCE_GROUP')) {
            if (-not $outputs.$required) {
                throw "azd environment '$EnvironmentName' has no '$required' output. Run a full './scripts/setup.ps1 -EnvironmentName $EnvironmentName' first."
            }
        }

        Initialize-Database `
            -ServerName $outputs.POSTGRES_SERVER_NAME `
            -Database $outputs.POSTGRES_DATABASE `
            -FunctionAppName $outputs.FUNCTION_APP_NAME `
            -ResourceGroup $outputs.AZURE_RESOURCE_GROUP `
            -AdminUser (Get-EntraAdminPrincipalName)

        Write-Host ''
        Write-Host 'Database schema update complete.' -ForegroundColor Green
        return
    }

    # ---- 3. App registration ------------------------------------------------
    Write-Step "Configuring Entra ID app registration '$AppRegistrationDisplayName'"
    # On a re-run the Static Web App already exists, so pass its hostname straight
    # away instead of waiting for the post-deployment pass.
    $knownSwaUrl = azd env get-value STATIC_WEB_APP_URL 2>$null
    if ($LASTEXITCODE -ne 0) { $knownSwaUrl = $null }

    $appRegArgs = @{
        DisplayName    = $AppRegistrationDisplayName
        LocalDevOrigin = $LocalDevOrigin
        ApplyToAzdEnv  = $true
    }
    if ($knownSwaUrl) { $appRegArgs.StaticWebAppHostname = $knownSwaUrl }
    & "$scriptRoot/setup-app-registration.ps1" @appRegArgs

    # ---- 4. Remaining azd settings -----------------------------------------
    Write-Step 'Writing azd environment settings'
    $signedInUserJson = az ad signed-in-user show -o json 2>$null
    $signedInUser = if ($LASTEXITCODE -eq 0 -and $signedInUserJson) { $signedInUserJson | ConvertFrom-Json } else { $null }
    if ($signedInUser) {
        $adminObjectId = $signedInUser.id
        $adminPrincipalName = if ($signedInUser.userPrincipalName) { $signedInUser.userPrincipalName } else { $signedInUser.displayName }
        $adminPrincipalType = 'User'
    }
    else {
        # Service principal / managed identity context: fall back to the signed-in client id.
        $spAppId = az account show --query 'user.name' -o tsv
        $sp = az ad sp show --id $spAppId -o json | ConvertFrom-Json
        $adminObjectId = $sp.id
        $adminPrincipalName = $sp.displayName
        $adminPrincipalType = 'ServicePrincipal'
    }

    Write-Host "  PostgreSQL Entra admin: $adminPrincipalName ($adminObjectId, $adminPrincipalType)"
    # AZURE_TENANT_ID is also a main.bicep output, but azd packages services in parallel
    # with provisioning, so the web build runs before any output reaches the environment.
    # generate-config.mjs refuses to emit a config without a tenant id, which fails
    # `azd up` during packaging. Seed the value here, where it is already known.
    Invoke-Checked { azd env set AZURE_TENANT_ID $account.tenantId } 'azd env set AZURE_TENANT_ID'
    Invoke-Checked { azd env set AZURE_LOCATION $Location } 'azd env set AZURE_LOCATION'
    Invoke-Checked { azd env set STATIC_WEB_APP_LOCATION $StaticWebAppLocation } 'azd env set STATIC_WEB_APP_LOCATION'
    Invoke-Checked { azd env set POSTGRES_ENTRA_ADMIN_OBJECT_ID $adminObjectId } 'azd env set POSTGRES_ENTRA_ADMIN_OBJECT_ID'
    Invoke-Checked { azd env set POSTGRES_ENTRA_ADMIN_PRINCIPAL_NAME $adminPrincipalName } 'azd env set POSTGRES_ENTRA_ADMIN_PRINCIPAL_NAME'
    Invoke-Checked { azd env set POSTGRES_ENTRA_ADMIN_PRINCIPAL_TYPE $adminPrincipalType } 'azd env set POSTGRES_ENTRA_ADMIN_PRINCIPAL_TYPE'
    Invoke-Checked { azd env set PUBLIC_NETWORK_ACCESS $PublicNetworkAccess } 'azd env set PUBLIC_NETWORK_ACCESS'
    Invoke-Checked { azd env set USE_CUSTOM_FOUNDRY_STORAGE $UseCustomFoundryStorage } 'azd env set USE_CUSTOM_FOUNDRY_STORAGE'
    Write-Host '  PostgreSQL admin password: generated by Bicep and stored in Key Vault.'

    if ($SkipDeploy) {
        Write-Host ''
        Write-Host "Environment configured. Run 'azd up' when you are ready to deploy." -ForegroundColor Green
        return
    }

    # ---- 5. Provision + deploy ---------------------------------------------
    Write-Step 'Provisioning and deploying (azd up)'
    Invoke-Checked { azd up --no-prompt } 'azd up'

    $outputs = azd env get-values -o json | ConvertFrom-Json

    # ---- 6. Post-deployment app registration + web redeploy -----------------
    $swaUrl = $outputs.STATIC_WEB_APP_URL
    if ($swaUrl) {
        Write-Step 'Registering the Static Web App origin with the app registration'
        & "$scriptRoot/setup-app-registration.ps1" `
            -DisplayName $AppRegistrationDisplayName `
            -StaticWebAppHostname $swaUrl `
            -LocalDevOrigin $LocalDevOrigin `
            -SkipSecret

        Write-Step 'Redeploying the web client with the final configuration'
        Invoke-Checked { azd deploy web --no-prompt } 'azd deploy web'
    }
    else {
        Write-Warning 'STATIC_WEB_APP_URL was not found in the azd outputs; skipping the redirect URI update.'
    }

    # ---- 7. Database initialization ----------------------------------------
    if (-not $SkipDatabaseInit) {
        Write-Step 'Initializing the database'
        # Step 4 registered $adminPrincipalName as the server's Entra administrator. Left to
        # its own default, setup-database.ps1 would connect as the Azure CLI account name,
        # which differs for guest users and is rejected at login.
        Initialize-Database `
            -ServerName $outputs.POSTGRES_SERVER_NAME `
            -Database $outputs.POSTGRES_DATABASE `
            -FunctionAppName $outputs.FUNCTION_APP_NAME `
            -ResourceGroup $outputs.AZURE_RESOURCE_GROUP `
            -AdminUser $adminPrincipalName
    }

    # ---- Summary ------------------------------------------------------------
    Write-Host ''
    Write-Host 'Setup complete.' -ForegroundColor Green
    Write-Host "  Web app       : $($outputs.STATIC_WEB_APP_URL)"
    Write-Host "  API           : $($outputs.FUNCTION_APP_URL)"
    Write-Host "  PostgreSQL    : $($outputs.POSTGRES_FQDN)"
    Write-Host "  Key Vault     : $($outputs.KEY_VAULT_URI)"
    Write-Host "  Admin password: Key Vault secret '$($outputs.POSTGRES_ADMIN_SECRET_NAME)'"
    if ($SkipDatabaseInit) {
        Write-Host ''
        Write-Host 'Remaining step - apply the database schema:'
        Write-Host "  ./scripts/setup.ps1 -EnvironmentName $EnvironmentName -DatabaseOnly"
    }
}
finally {
    Pop-Location
}
