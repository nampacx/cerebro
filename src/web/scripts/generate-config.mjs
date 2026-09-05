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
if (!tenantId || !clientId) {
  console.warn('[generate-config] Tenant/client id missing; sign-in will need manual configuration.');
}

writeFileSync(
  join(publicDir, 'config.json'),
  JSON.stringify(
    {
      apiBaseUrl: apiBaseUrl.replace(/\/$/, ''),
      tenantId,
      clientId,
      apiScope: clientId ? `api://${clientId}/access_as_user` : ''
    },
    null,
    2
  )
);

const template = readFileSync(join(root, 'staticwebapp.config.template.json'), 'utf8');
const swaConfig = template.replace('AZURE_TENANT_ID', tenantId || 'organizations');
writeFileSync(join(publicDir, 'staticwebapp.config.json'), swaConfig);

console.log('[generate-config] Wrote public/config.json and public/staticwebapp.config.json');
