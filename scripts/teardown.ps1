<#
.SYNOPSIS
Tears down everything `setup.ps1` created so the next deployment starts from a clean slate.

What it does, in order:
  1. Verifies prerequisites (az, azd) and that you are signed in to both.
  2. Runs `azd down --force --purge`.
     --purge matters: resource names are derived from uniqueString(subscription id,
     environment name), so a redeploy under the same environment name reuses the exact
     same names. Key Vault and the Foundry account are soft-deleted rather than removed,
     and their tombstones would then collide with the new deployment ("a resource with
     this name already exists or is in a conflicting state").
  3. Optionally deletes the Entra ID app registration, which lives in the directory
     rather than the resource group and is therefore untouched by azd down.
  4. Clears the azd environment values that refer to now-deleted resources, so a later
     setup.ps1 run cannot reuse a stale client id or secret.

.EXAMPLE
./scripts/teardown.ps1 -EnvironmentName cerebro-dev

.EXAMPLE
# Also remove the Entra app registration created by setup.ps1.
./scripts/teardown.ps1 -EnvironmentName cerebro-dev -DeleteAppRegistration

.EXAMPLE
# Remove the azd environment definition as well, so nothing local is left behind.
./scripts/teardown.ps1 -EnvironmentName cerebro-dev -DeleteAppRegistration -DeleteAzdEnvironment
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [string] $EnvironmentName,
    [string] $AppRegistrationDisplayName,
    [switch] $DeleteAppRegistration,
    [switch] $DeleteAzdEnvironment,
    [switch] $Force
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

Push-Location $repoRoot
try {
    Write-Step 'Checking prerequisites'
    foreach ($tool in 'az', 'azd') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' was not found on PATH. Install it and try again."
        }
    }

    az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Not signed in to Azure CLI. Run 'az login' first." }

    $envList = azd env list -o json 2>$null | ConvertFrom-Json
    if (-not ($envList | Where-Object { $_.Name -eq $EnvironmentName })) {
        throw "azd environment '$EnvironmentName' does not exist. Nothing to tear down."
    }

    $resourceGroup = (azd env get-value AZURE_RESOURCE_GROUP -e $EnvironmentName 2>$null)
    if ($LASTEXITCODE -ne 0) { $resourceGroup = '<unknown>' }

    if (-not $Force -and -not $PSCmdlet.ShouldProcess(
            "environment '$EnvironmentName' (resource group $resourceGroup)",
            'Permanently delete all Azure resources')) {
        Write-Host 'Aborted.'
        return
    }

    Write-Step "Deleting Azure resources for '$EnvironmentName'"
    Write-Host 'This permanently purges soft-deleted resources (Key Vault, Foundry account) so the names can be reused.'
    Invoke-Checked { azd down --force --purge -e $EnvironmentName } 'azd down'

    if ($DeleteAppRegistration) {
        Write-Step "Deleting Entra ID app registration '$AppRegistrationDisplayName'"
        # Prefer the id recorded by setup.ps1; fall back to the display name.
        $clientId = (azd env get-value AUTH_CLIENT_ID -e $EnvironmentName 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clientId)) { $clientId = $null }

        if (-not $clientId) {
            $existing = az ad app list --display-name $AppRegistrationDisplayName --query "[0]" -o json 2>$null | ConvertFrom-Json
            if ($existing) { $clientId = $existing.appId }
        }

        if ($clientId) {
            az ad app delete --id $clientId 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Deleted app registration $clientId."
            }
            else {
                Write-Warning "Could not delete app registration $clientId. Delete it manually in Entra ID if it is no longer needed."
            }
        }
        else {
            Write-Host "No app registration found for '$AppRegistrationDisplayName'; nothing to delete."
        }
    }
    else {
        Write-Host ''
        Write-Host "Note: the Entra ID app registration was left in place. Re-run with -DeleteAppRegistration to remove it." -ForegroundColor Yellow
    }

    if ($DeleteAzdEnvironment) {
        Write-Step "Removing local azd environment '$EnvironmentName'"
        $envPath = Join-Path $repoRoot ".azure/$EnvironmentName"
        if (Test-Path $envPath) {
            Remove-Item -Recurse -Force $envPath
            Write-Host "Removed $envPath."
        }
    }
    else {
        # Values that point at resources which no longer exist. Leaving them behind makes a
        # later setup.ps1 run look like it succeeded while wiring up a deleted app registration.
        Write-Step 'Clearing stale azd environment values'
        foreach ($key in 'AUTH_CLIENT_ID', 'AUTH_CLIENT_SECRET', 'STATIC_WEB_APP_URL', 'APP_CONFIG_NAME', 'APP_CONFIG_ENDPOINT') {
            azd env set $key '' -e $EnvironmentName 2>$null | Out-Null
        }
        Write-Host 'Cleared AUTH_CLIENT_ID, AUTH_CLIENT_SECRET, STATIC_WEB_APP_URL and App Configuration values.'
    }

    Write-Host ''
    Write-Host 'Teardown complete.' -ForegroundColor Green
    Write-Host "Start fresh with: ./scripts/setup.ps1 -EnvironmentName $EnvironmentName"
}
finally {
    Pop-Location
}
