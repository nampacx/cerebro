<#
.SYNOPSIS
Sets up the Cerebro database: creates the managed-identity role for the function app
and applies db/schema.sql with grants. Run after `azd up` while connected to a
network that can reach the PostgreSQL server (private endpoint or temporary
public access).

When the server is publicly reachable, this machine's address is added to its
firewall first - see the note in Set-ClientFirewallRule for why public network
access does not imply that on its own.

.EXAMPLE
./scripts/setup-database.ps1 -ServerName psql-abc123 -Database ragdb -FunctionAppName func-abc123

.EXAMPLE
# Connect as an explicit administrator instead of resolving the signed-in one.
./scripts/setup-database.ps1 -ServerName psql-abc123 -FunctionAppName func-abc123 -AdminUser 'admin@contoso.com'

.EXAMPLE
# From inside the VNet, where the private endpoint already provides a route.
./scripts/setup-database.ps1 -ServerName psql-abc123 -FunctionAppName func-abc123 -SkipFirewallRule
#>
param(
    [Parameter(Mandatory)] [string] $ServerName,
    [string] $Database = 'ragdb',
    [Parameter(Mandatory)] [string] $FunctionAppName,
    [string] $AdminUser,
    [string] $ResourceGroup,
    [string] $FirewallRuleName = 'setup-client-ip',
    [switch] $SkipFirewallRule
)

$ErrorActionPreference = 'Stop'

function Get-PublicIpAddress {
    # Azure reports no caller address, so ask an echo service. Several are tried because
    # any one of them can be blocked by a proxy while the others still answer.
    # Each URL is the IPv4-only host of its service: a dual-stack endpoint answers with
    # this machine's IPv6 address whenever it can, and Flexible Server firewall rules are
    # IPv4-only - so that reply is not merely unusable, it is the wrong address.
    foreach ($url in @('https://api.ipify.org', 'https://ipv4.icanhazip.com', 'https://checkip.amazonaws.com')) {
        try {
            $ip = "$(Invoke-RestMethod -Uri $url -TimeoutSec 10)".Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        }
        catch {
            continue
        }
    }
    return $null
}

function Set-ClientFirewallRule {
    # Enabling public network access only opens the listener. Flexible Server still drops
    # traffic from every address without a matching firewall rule, and a dropped packet
    # times out rather than being refused - so a missing rule presents as a server that is
    # down, not as a door that is closed. Nothing under infra/ declares a rule, which
    # leaves this the one step between a finished `azd up` and a reachable database.
    param([string] $Server, [string] $Group, [string] $RuleName)

    if (-not $Group) {
        $Group = az postgres flexible-server list --query "[?name=='$Server'].resourceGroup | [0]" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) { $Group = $null }
    }
    if ([string]::IsNullOrWhiteSpace($Group)) {
        Write-Warning "Could not resolve the resource group for '$Server'; leaving the firewall untouched. Pass -ResourceGroup, or -SkipFirewallRule when connecting from inside the VNet."
        return
    }

    $clientIp = Get-PublicIpAddress
    if (-not $clientIp) {
        Write-Warning "Could not determine this machine's public IP address; leaving the firewall untouched."
        return
    }

    # `firewall-rule create` upserts, so re-running narrows the existing rule to the
    # current address instead of accumulating one rule per address seen over time.
    Write-Host "Allowing $clientIp through the PostgreSQL firewall (rule '$RuleName') ..."
    az postgres flexible-server firewall-rule create `
        --resource-group $Group --server-name $Server --name $RuleName `
        --start-ip-address $clientIp --end-ip-address $clientIp `
        --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not create the firewall rule; continuing in case this address is already allowed."
    }
}

function Test-PostgresConnection {
    param([string] $ConnectionString)
    psql $ConnectionString -v ON_ERROR_STOP=1 -c 'SELECT 1;' *> $null
    return $LASTEXITCODE -eq 0
}

# The server authenticates Entra logins against the principal name registered as its
# administrator, which is the directory UPN - not the account name Azure CLI reports.
# The two differ for guest users (alice_contoso.com#EXT#@tenant.onmicrosoft.com), so read
# the directory value first and fall back for service principal contexts, where
# `az ad signed-in-user show` has nothing to return.
if (-not $AdminUser) {
    $AdminUser = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AdminUser)) {
        $AdminUser = az account show --query user.name -o tsv
    }
}

Write-Host "Connecting to $ServerName as $AdminUser"
$token = az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv
$env:PGPASSWORD = $token
$hostName = "$ServerName.postgres.database.azure.com"

if (-not $SkipFirewallRule) {
    Set-ClientFirewallRule -Server $ServerName -Group $ResourceGroup -RuleName $FirewallRuleName
}

# A new rule is not always in force the moment the control plane returns. Without this
# wait each psql call below would fail separately against a server that is seconds away
# from accepting the very same connection.
$adminConnection = "host=$hostName dbname=postgres user=$AdminUser sslmode=require"
Write-Host "Waiting for $hostName to accept connections ..."
$connected = $false
for ($attempt = 1; $attempt -le 6; $attempt++) {
    if (Test-PostgresConnection -ConnectionString $adminConnection) { $connected = $true; break }
    if ($attempt -lt 6) { Start-Sleep -Seconds 10 }
}
if (-not $connected) {
    throw "Could not connect to $hostName as '$AdminUser' after 6 attempts. Check that this machine's address is allowed through the firewall (or pass -SkipFirewallRule from inside the VNet), and that '$AdminUser' is the server's Entra administrator."
}

Write-Host "Creating Entra principal role for $FunctionAppName ..."
$principalResult = psql $adminConnection -v ON_ERROR_STOP=1 `
    -c "SELECT * FROM pgaadauth_create_principal('$FunctionAppName', false, false);" 2>&1
if ($LASTEXITCODE -ne 0) {
    # A role left over from an earlier run is the expected failure here. Discarding every
    # other one - a login rejected because $AdminUser is not the registered administrator,
    # above all - only moves the error to the schema step, where it reads as unrelated.
    if ($principalResult -match 'already exists') {
        Write-Host "Role already exists, continuing."
    }
    else {
        $principalResult | ForEach-Object { Write-Host $_ }
        # Never reaching the server and being rejected by it need different remedies, and
        # the two are easy to confuse: a blocked address times out rather than refusing.
        $hint = if ($principalResult -match 'timed out|could not connect|No route to host|Connection refused') {
            "The server did not accept the connection. Public network access alone is not enough - PostgreSQL Flexible Server drops traffic from any address without a matching firewall rule, so add one for this machine or run from inside the VNet."
        }
        else {
            "'$AdminUser' must be the server's Entra administrator (POSTGRES_ENTRA_ADMIN_PRINCIPAL_NAME in the azd environment)."
        }
        throw "Could not create the Entra principal role for '$FunctionAppName' as '$AdminUser'. $hint"
    }
}

Write-Host "Applying schema to $Database ..."
psql "host=$hostName dbname=$Database user=$AdminUser sslmode=require" -v ON_ERROR_STOP=1 -f "$PSScriptRoot/../db/schema.sql"

Write-Host "Granting application permissions ..."
psql "host=$hostName dbname=$Database user=$AdminUser sslmode=require" -v ON_ERROR_STOP=1 -c @"
GRANT USAGE ON SCHEMA public TO "$FunctionAppName";
GRANT SELECT, INSERT, UPDATE, DELETE ON documents, document_acl, chunks, conversations TO "$FunctionAppName";
"@

Write-Host "Done."
