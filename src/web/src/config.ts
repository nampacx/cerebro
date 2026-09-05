export interface AppConfig {
  apiBaseUrl: string;
  tenantId: string;
  clientId: string;
  apiScope: string;
}

let cached: AppConfig | null = null;

export async function loadConfig(): Promise<AppConfig> {
  if (cached) {
    return cached;
  }

  const response = await fetch('/config.json', { cache: 'no-store' });
  if (!response.ok) {
    throw new Error('Unable to load application configuration (config.json).');
  }

  cached = (await response.json()) as AppConfig;
  return cached;
}
