<#
.SYNOPSIS
One-shot setup for the RAG solution: Entra ID app registration + azd environment
configuration + provisioning and deployment.

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
  7. Optionally initializes the database: opens the PostgreSQL firewall for this
     machine, then applies the schema and the managed-identity role.

.EXAMPLE
./scripts/setup.ps1 -EnvironmentName rag-dev

.EXAMPLE
# Dev/test with public network access so the database can be initialized from your machine.
./scripts/setup.ps1 -EnvironmentName rag-dev -PublicNetworkAccess Enabled -InitializeDatabase

.EXAMPLE
# Only refresh the app registration and azd settings, skip deployment.
./scripts/setup.ps1 -EnvironmentName rag-dev -SkipDeploy
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
    [switch] $InitializeDatabase,
    [switch] $SkipDeploy
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptRoot

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
    else {
        Invoke-Checked { azd env new $EnvironmentName --location $Location --subscription $account.id } 'azd env new'
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
    if ($InitializeDatabase) {
        Write-Step 'Initializing the database'
        if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
            Write-Warning "'psql' was not found on PATH; skipping. Run scripts/setup-database.ps1 manually."
        }
        elseif ($PublicNetworkAccess -ne 'Enabled') {
            Write-Warning 'PUBLIC_NETWORK_ACCESS is Disabled; the server is only reachable from inside the VNet. Run scripts/setup-database.ps1 from a connected network.'
        }
        else {
            # Step 4 registered $adminPrincipalName as the server's Entra administrator.
            # Left to its own default, setup-database.ps1 would connect as the Azure CLI
            # account name, which differs for guest users and is rejected at login.
            # -ResourceGroup lets setup-database.ps1 open the PostgreSQL firewall for this
            # machine without having to look the group up; -AdminUser keeps the connecting
            # identity identical to the administrator step 4 registered on the server.
            & "$scriptRoot/setup-database.ps1" `
                -ServerName $outputs.POSTGRES_SERVER_NAME `
                -Database $outputs.POSTGRES_DATABASE `
                -FunctionAppName $outputs.FUNCTION_APP_NAME `
                -AdminUser $adminPrincipalName `
                -ResourceGroup $outputs.AZURE_RESOURCE_GROUP
        }
    }

    # ---- Summary ------------------------------------------------------------
    Write-Host ''
    Write-Host 'Setup complete.' -ForegroundColor Green
    Write-Host "  Web app       : $($outputs.STATIC_WEB_APP_URL)"
    Write-Host "  API           : $($outputs.FUNCTION_APP_URL)"
    Write-Host "  PostgreSQL    : $($outputs.POSTGRES_FQDN)"
    Write-Host "  Key Vault     : $($outputs.KEY_VAULT_URI)"
    Write-Host "  Admin password: Key Vault secret '$($outputs.POSTGRES_ADMIN_SECRET_NAME)'"
    if (-not $InitializeDatabase) {
        Write-Host ''
        Write-Host 'Remaining step - initialize the database from a network that can reach the server:'
        Write-Host "  ./scripts/setup-database.ps1 -ServerName $($outputs.POSTGRES_SERVER_NAME) -FunctionAppName $($outputs.FUNCTION_APP_NAME)"
    }
}
finally {
    Pop-Location
}
