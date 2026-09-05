<#
.SYNOPSIS
Sets up the RAG database: creates the managed-identity role for the function app
and applies db/schema.sql with grants. Run after `azd up` while connected to a
network that can reach the PostgreSQL server (private endpoint or temporary
public access).

.EXAMPLE
./scripts/setup-database.ps1 -ServerName psql-abc123 -Database ragdb -FunctionAppName func-abc123
#>
param(
    [Parameter(Mandatory)] [string] $ServerName,
    [string] $Database = 'ragdb',
    [Parameter(Mandatory)] [string] $FunctionAppName,
    [string] $AdminUser = (az account show --query user.name -o tsv)
)

$ErrorActionPreference = 'Stop'
$token = az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv
$env:PGPASSWORD = $token
$hostName = "$ServerName.postgres.database.azure.com"

Write-Host "Creating Entra principal role for $FunctionAppName ..."
psql "host=$hostName dbname=postgres user=$AdminUser sslmode=require" -v ON_ERROR_STOP=1 `
    -c "SELECT * FROM pgaadauth_create_principal('$FunctionAppName', false, false);" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Role may already exist, continuing." }

Write-Host "Applying schema to $Database ..."
psql "host=$hostName dbname=$Database user=$AdminUser sslmode=require" -v ON_ERROR_STOP=1 -f "$PSScriptRoot/../db/schema.sql"

Write-Host "Granting application permissions ..."
psql "host=$hostName dbname=$Database user=$AdminUser sslmode=require" -v ON_ERROR_STOP=1 -c @"
GRANT USAGE ON SCHEMA public TO "$FunctionAppName";
GRANT SELECT, INSERT, DELETE ON documents, document_acl, chunks TO "$FunctionAppName";
"@

Write-Host "Done."
