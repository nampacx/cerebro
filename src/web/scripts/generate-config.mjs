// Generates the runtime artifacts that depend on the deployed Azure environment:
//   public/config.json               - consumed by the SPA at startup
//   public/staticwebapp.config.json  - Static Web Apps auth + routing configuration
//
// Values come from the azd environment (azd exports infra outputs as env vars) and
// fall back to VITE_* variables for local development.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const publicDir = join(root, 'public');
mkdirSync(publicDir, { recursive: true });

const apiBaseUrl =
  process.env.VITE_API_BASE_URL || process.env.WEB_API_BASE_URL || process.env.FUNCTION_APP_URL || '';
const tenantId = process.env.VITE_AZURE_TENANT_ID || process.env.AZURE_TENANT_ID || '';
const clientId = process.env.VITE_AZURE_CLIENT_ID || process.env.AUTH_CLIENT_ID || '';

if (!apiBaseUrl) {
  console.warn('[generate-config] No API base URL found; the SPA will call same-origin /api.');
}

// The tenant id is baked into `openIdIssuer` below, which cannot use app-setting
// indirection the way the client id and secret do - it has to be a literal.
// A missing value used to fall back to the multi-tenant `organizations` endpoint,
// whose discovery document advertises a templated issuer
// ("https://login.microsoftonline.com/{tenantid}/v2.0"). Static Web Apps cannot
// resolve that against a single-tenant (AzureADMyOrg) app registration, so
// /.auth/login/aad redirects to itself with a fresh nonce forever and never
// reaches Entra. Fail the build instead: an infinite sign-in loop on the deployed
// site is far harder to diagnose than an error here.
if (!tenantId || !clientId) {
  throw new Error(
    '[generate-config] Tenant/client id missing - sign-in would break with an infinite redirect loop.\n' +
      "  Set them in the azd environment:  azd env set AZURE_TENANT_ID <guid>\n" +
      '  or, for a standalone build, export VITE_AZURE_TENANT_ID / VITE_AZURE_CLIENT_ID.'
  );
}

writeFileSync(
  join(publicDir, 'config.json'),
  JSON.stringify(
    {
      apiBaseUrl: apiBaseUrl.replace(/\/$/, ''),
      tenantId,
      clientId,
      apiScope: `api://${clientId}/access_as_user`
    },
    null,
    2
  )
);

const template = readFileSync(join(root, 'staticwebapp.config.template.json'), 'utf8');
const swaConfig = template.replace('AZURE_TENANT_ID', tenantId);
writeFileSync(join(publicDir, 'staticwebapp.config.json'), swaConfig);

console.log(`[generate-config] Wrote public/config.json and public/staticwebapp.config.json (tenant ${tenantId})`);
