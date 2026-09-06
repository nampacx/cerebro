<#
.SYNOPSIS
Creates (or updates) the Entra ID app registration used by the RAG API, the
Static Web App sign-in and the A2A on-behalf-of flow.

The registration is required — the Function App validates Entra ID access tokens
and derives the `oid` / `groups` claims that drive PostgreSQL row-level security.

What it configures:
  * Application ID URI `api://<client-id>` and the `access_as_user` delegated scope
  * The `groups` claim on access tokens (security groups; used for RLS sharing)
  * SPA redirect URIs for the Static Web App and local Vite dev server
  * A web redirect URI, plus ID token issuance, for the Static Web Apps built-in Entra provider
  * Pre-authorization of the SPA against its own API so users are not prompted twice
  * A client secret for the Static Web Apps auth provider
  * Tenant-wide admin consent for that scope (skipped with -SkipAdminConsent)

.EXAMPLE
./scripts/setup-app-registration.ps1 -DisplayName rag-app -StaticWebAppHostname swa-abc123.azurestaticapps.net -ApplyToAzdEnv

.EXAMPLE
# Before the Static Web App exists; re-run later with -StaticWebAppHostname to add the redirect URIs.
./scripts/setup-app-registration.ps1 -DisplayName rag-app
#>
param(
    [string] $DisplayName = 'rag-app',
    [string] $StaticWebAppHostname,
    [string] $LocalDevOrigin = 'http://localhost:5173',
    [switch] $SkipSecret,
    [switch] $SkipAdminConsent,
    [switch] $ApplyToAzdEnv
)

$ErrorActionPreference = 'Stop'

function Invoke-GraphPatch {
    param([string] $ObjectId, [hashtable] $Body)

    $file = New-TemporaryFile
    try {
        ($Body | ConvertTo-Json -Depth 10) | Set-Content -Path $file -Encoding utf8
        az rest --method PATCH `
            --url "https://graph.microsoft.com/v1.0/applications/$ObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$file" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Microsoft Graph PATCH failed." }
    }
    finally {
        Remove-Item $file -ErrorAction SilentlyContinue
    }
}

Write-Host "Signing in context:" (az account show --query 'user.name' -o tsv)

# ---- 1. Create or reuse the application ------------------------------------
$existing = az ad app list --display-name $DisplayName --query "[0]" -o json | ConvertFrom-Json
if ($existing) {
    Write-Host "Reusing existing app registration '$DisplayName' ($($existing.appId))."
    $app = $existing
}
else {
    Write-Host "Creating app registration '$DisplayName' ..."
    $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json
}

$appId = $app.appId
$objectId = $app.id

# Reuse the existing scope id when re-running so consent grants stay valid.
$scopeId = $app.api.oauth2PermissionScopes `
    | Where-Object { $_.value -eq 'access_as_user' } `
    | Select-Object -ExpandProperty id -First 1
if (-not $scopeId) { $scopeId = [guid]::NewGuid().ToString() }

# ---- 2. Identifier URI + exposed API scope ---------------------------------
# Graph replaces the whole `api` object on PATCH, so the scope definition is
# reused verbatim in the second call below.
$apiScopes = @(
    @{
        id                      = $scopeId
        value                   = 'access_as_user'
        type                    = 'User'
        isEnabled               = $true
        adminConsentDisplayName = 'Access the RAG API as the signed-in user'
        adminConsentDescription = 'Allows the app to call the RAG API on behalf of the signed-in user. Row-level security is applied to that user.'
        userConsentDisplayName  = 'Access the RAG API on your behalf'
        userConsentDescription  = 'Allows the app to read and write your documents and conversations in the RAG API.'
    }
)

Write-Host "Configuring API scope 'access_as_user' ..."
Invoke-GraphPatch -ObjectId $objectId -Body @{
    identifierUris        = @("api://$appId")
    groupMembershipClaims = 'SecurityGroup'
    api                   = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = $apiScopes
    }
}

# ---- 3. Redirect URIs, groups claim, self pre-authorization -----------------
$spaRedirects = @($LocalDevOrigin)
$webRedirects = @()
if ($StaticWebAppHostname) {
    $swaOrigin = "https://$($StaticWebAppHostname -replace '^https?://', '')"
    $spaRedirects += $swaOrigin
    $webRedirects += "$swaOrigin/.auth/login/aad/callback"
}
else {
    Write-Warning "No -StaticWebAppHostname supplied; re-run after 'azd up' to add the Static Web App redirect URIs."
}

Write-Host "Configuring redirect URIs and token claims ..."
Invoke-GraphPatch -ObjectId $objectId -Body @{
    spa                   = @{ redirectUris = $spaRedirects }
    web                   = @{
        redirectUris          = $webRedirects
        # The Static Web Apps runtime signs users in with the hybrid flow
        # (`response_type=code id_token`), so Entra must be allowed to issue an ID token
        # from the authorize endpoint. Without this it rejects the request and posts the
        # error back to /.auth/login/aad/callback: Static Web Apps never sets its auth
        # cookie, every page then 401s, and the 401 response override in
        # staticwebapp.config.json sends the browser back to /.auth/login/aad - so
        # sign-in loops instead of failing visibly. Graph replaces the whole `web`
        # object on PATCH, so this has to be set here; a portal toggle would be undone
        # by the next run of this script.
        implicitGrantSettings = @{ enableIdTokenIssuance = $true }
    }
    optionalClaims        = @{
        accessToken = @(@{ name = 'groups'; essential = $false; additionalProperties = @() })
        idToken     = @(@{ name = 'groups'; essential = $false; additionalProperties = @() })
    }
    requiredResourceAccess = @(
        @{
            resourceAppId  = $appId
            resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
        }
    )
    api                   = @{
        requestedAccessTokenVersion = 2
        oauth2PermissionScopes      = $apiScopes
        preAuthorizedApplications   = @(
            @{ appId = $appId; delegatedPermissionIds = @($scopeId) }
        )
    }
}

# ---- 4. Service principal ---------------------------------------------------
$sp = az ad sp list --filter "appId eq '$appId'" --query "[0]" -o json | ConvertFrom-Json
if (-not $sp) {
    Write-Host "Creating service principal ..."
    az ad sp create --id $appId -o none
}

# ---- 5. Client secret for the Static Web Apps auth provider -----------------
$secret = $null
if (-not $SkipSecret) {
    Write-Host "Creating client secret ..."
    $credential = az ad app credential reset --id $appId --append `
        --display-name 'static-web-app' --years 1 -o json | ConvertFrom-Json
    $secret = $credential.password
}

# ---- 6. Admin consent -------------------------------------------------------
# The SPA asks for this app's own scope, so without a tenant-wide grant each user is
# consented individually - and the Static Web Apps built-in provider has nowhere to show
# that prompt, so sign-in fails instead of asking. Granting it needs an administrator, so
# a failure here is reported rather than thrown: the deployment is otherwise complete and
# an administrator can run the single command afterwards.
$consentGranted = $false
if (-not $SkipAdminConsent) {
    Write-Host "Granting tenant-wide admin consent ..."
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        az ad app permission admin-consent --id $appId --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0) { $consentGranted = $true; break }
        # A service principal created seconds ago is not always visible to the consent
        # endpoint yet, so an initial failure is worth retrying before reporting it.
        if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
}

# ---- 7. Report ---------------------------------------------------------------
$tenantId = az account show --query tenantId -o tsv

Write-Host ''
Write-Host 'App registration ready:' -ForegroundColor Green
Write-Host "  Client id     : $appId"
Write-Host "  Tenant id     : $tenantId"
Write-Host "  API scope     : api://$appId/access_as_user"
if ($secret) { Write-Host "  Client secret : $secret  (shown once - store it now)" }

if ($ApplyToAzdEnv) {
    Write-Host ''
    Write-Host 'Writing values to the current azd environment ...'
    azd env set AUTH_CLIENT_ID $appId
    if ($secret) { azd env set AUTH_CLIENT_SECRET $secret }
}
else {
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host "  azd env set AUTH_CLIENT_ID $appId"
    if ($secret) { Write-Host "  azd env set AUTH_CLIENT_SECRET '<the secret above>'" }
}

Write-Host ''
if ($consentGranted) {
    Write-Host 'Admin consent granted for the tenant.' -ForegroundColor Green
}
elseif ($SkipAdminConsent) {
    Write-Host 'Admin consent skipped. Every user is prompted individually until an administrator runs:'
    Write-Host "  az ad app permission admin-consent --id $appId"
}
else {
    Write-Warning 'Could not grant admin consent - the signed-in account is most likely not a Global, Privileged Role or Cloud Application Administrator.'
    Write-Host 'Sign-in will not work until an administrator runs:'
    Write-Host "  az ad app permission admin-consent --id $appId"
}
