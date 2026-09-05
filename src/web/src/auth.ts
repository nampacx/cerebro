import {
  PublicClientApplication,
  InteractionRequiredAuthError,
  type AccountInfo
} from '@azure/msal-browser';
import { loadConfig } from './config';

export interface SignedInUser {
  name: string;
  userId: string;
}

/**
 * Static Web Apps built-in Entra ID authentication gates access to the site and
 * provides the signed-in identity via /.auth/me. It does not hand out access
 * tokens for downstream APIs, so MSAL performs a silent SSO against the same
 * Entra tenant to obtain a bearer token for the Function App API.
 */
interface ClientPrincipal {
  identityProvider: string;
  userId: string;
  userDetails: string;
  userRoles: string[];
}

let msal: PublicClientApplication | null = null;
let account: AccountInfo | null = null;

export async function getSignedInUser(): Promise<SignedInUser | null> {
  const response = await fetch('/.auth/me');
  if (!response.ok) {
    return null;
  }

  const payload = (await response.json()) as { clientPrincipal: ClientPrincipal | null };
  if (!payload.clientPrincipal) {
    return null;
  }

  return {
    name: payload.clientPrincipal.userDetails,
    userId: payload.clientPrincipal.userId
  };
}

export function login(): void {
  window.location.href = `/.auth/login/aad?post_login_redirect_uri=${encodeURIComponent(
    window.location.pathname
  )}`;
}

export function logout(): void {
  window.location.href = '/.auth/logout';
}

async function getMsal(): Promise<PublicClientApplication> {
  if (msal) {
    return msal;
  }

  const config = await loadConfig();
  msal = new PublicClientApplication({
    auth: {
      clientId: config.clientId,
      authority: `https://login.microsoftonline.com/${config.tenantId}`,
      redirectUri: window.location.origin
    },
    cache: {
      cacheLocation: 'sessionStorage'
    }
  });

  await msal.initialize();
  return msal;
}

export async function getApiToken(): Promise<string> {
  const config = await loadConfig();
  const client = await getMsal();
  const scopes = [config.apiScope];

  if (!account) {
    const accounts = client.getAllAccounts();
    account = accounts[0] ?? null;
  }

  if (!account) {
    const user = await getSignedInUser();
    try {
      const result = await client.ssoSilent({ scopes, loginHint: user?.name });
      account = result.account;
      return result.accessToken;
    } catch {
      const result = await client.loginPopup({ scopes, loginHint: user?.name });
      account = result.account;
      return result.accessToken;
    }
  }

  try {
    const result = await client.acquireTokenSilent({ scopes, account });
    return result.accessToken;
  } catch (error) {
    if (error instanceof InteractionRequiredAuthError) {
      const result = await client.acquireTokenPopup({ scopes, account });
      return result.accessToken;
    }
    throw error;
  }
}
