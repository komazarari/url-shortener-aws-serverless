/**
 * Configuration loading.
 *
 * Lambda@Edge cannot use environment variables, so settings live in a
 * base64-encoded JSON blob in Secrets Manager (us-east-1). The secret *name*
 * is baked into the bundle at build time via SM_CONFIG_KEY.json.
 */

export interface Config {
  client_id: string;
  client_secret: string;
  response_type: string;
  scope: string;
  grant_type: string;

  CALLBACK_BASE_URL: string;
  CALLBACK_PATH: string;
  DISCOVERY_DOCUMENT_URL: string;
  PRIVATE_KEY: string;
  PUBLIC_KEY: string;
  SESSION_DURATION: number;

  /** Exact-match allowlist of permitted email addresses. Compared lowercased. */
  ALLOWED_EMAILS: string[];

  /** Paths answered with 401 JSON instead of a redirect to the IdP. */
  JSON_PATH_PREFIXES?: string[];

  /**
   * Optional: supply the endpoints directly and the discovery document is
   * never fetched. Worth doing at the edge, where the 5 second budget makes
   * every avoidable round trip a liability. All four must be present to take
   * effect. For Google they are stable.
   */
  ISSUER?: string;
  AUTHORIZATION_ENDPOINT?: string;
  TOKEN_ENDPOINT?: string;
  JWKS_URI?: string;
}

const REQUIRED_KEYS: (keyof Config)[] = [
  'client_id',
  'client_secret',
  'response_type',
  'scope',
  'grant_type',
  'CALLBACK_BASE_URL',
  'CALLBACK_PATH',
  'DISCOVERY_DOCUMENT_URL',
  'PRIVATE_KEY',
  'PUBLIC_KEY',
  'SESSION_DURATION',
  'ALLOWED_EMAILS',
];

export function validateConfig(candidate: Partial<Config>): Config {
  const missing = REQUIRED_KEYS.filter((k) => candidate[k] === undefined);
  if (missing.length > 0) {
    throw new Error(`missing required config keys: ${missing.join(', ')}`);
  }

  const allowed = candidate.ALLOWED_EMAILS;
  if (!Array.isArray(allowed) || allowed.length === 0) {
    // An empty list would authenticate everyone and authorise no one, which is
    // a confusing way to be locked out. Fail loudly at load time instead.
    throw new Error('ALLOWED_EMAILS must be a non-empty array');
  }
  if (allowed.some((e) => typeof e !== 'string' || !e.includes('@'))) {
    throw new Error('ALLOWED_EMAILS must contain email addresses');
  }

  return candidate as Config;
}

export async function fetchConfigFromSecretsManager(secretId: string): Promise<Config> {
  // Imported lazily and kept external from the bundle: the SDK ships with the
  // Lambda runtime, and bundling it would exceed the 1 MB viewer limit.
  const { SecretsManagerClient, GetSecretValueCommand } = await import(
    '@aws-sdk/client-secrets-manager'
  );
  // Bounded so a stalled call surfaces as an error rather than eating the
  // whole 5 second viewer-request budget. Edge replicas reach us-east-1
  // cross-region, so this is the slowest hop on a cold start.
  const client = new SecretsManagerClient({
    region: 'us-east-1',
    maxAttempts: 2,
    requestHandler: { connectionTimeout: 1000, requestTimeout: 2000 },
  });
  const secret = await client.send(new GetSecretValueCommand({ SecretId: secretId }));

  if (secret.SecretString === undefined) {
    throw new Error('secret has no SecretString');
  }

  const encoded = JSON.parse(secret.SecretString).config as string;
  const decoded = JSON.parse(Buffer.from(encoded, 'base64').toString('utf-8'));
  return validateConfig(decoded);
}

export async function fetchConfigFromFile(path: string): Promise<Config> {
  const { readFile } = await import('node:fs/promises');
  try {
    return validateConfig(JSON.parse(await readFile(path, 'utf-8')));
  } catch (err) {
    throw new Error(`unable to read ${path}: ${err}`);
  }
}

export interface AuthRequest {
  [key: string]: string | undefined;
  client_id: string;
  response_type: string;
  redirect_uri: string;
  scope: string;
  state?: string;
  nonce?: string;
  code_challenge?: string;
  code_challenge_method?: 'S256';
}

export interface TokenRequest {
  [key: string]: string | undefined;
  client_id: string;
  client_secret: string;
  redirect_uri: string;
  grant_type: string;
  code: string;
  code_verifier?: string;
}
