/**
 * Exercises authenticate() end to end with a fake IdP.
 *
 * Real RSA keys and real JWT signing/verification; only the network is faked.
 * These are the tests that pin the behaviours the original sample got wrong.
 */

import assert from 'node:assert/strict';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { beforeEach, describe, it, mock } from 'node:test';
import JsonWebToken from 'jsonwebtoken';
import type { CloudFrontRequest, CloudFrontResultResponse } from 'aws-lambda';

import { authenticate, buildState, hashFromNonce, __setForTests } from '../src/auth.js';
import type { Config } from '../src/config.js';

const HOST = 'short.example.net';
const ALLOWED = 'you@example.com';

// Session-signing keypair (ours) and the IdP's id_token keypair.
const session = generateKeyPairSync('rsa', { modulusLength: 2048 });
const idp = generateKeyPairSync('rsa', { modulusLength: 2048 });

const sessionPrivate = session.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
const sessionPublic = session.publicKey.export({ type: 'spki', format: 'pem' }) as string;
const idpPrivate = idp.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
const idpJwk = { kid: 'test-key', ...idp.publicKey.export({ format: 'jwk' }) };

const config: Config = {
  client_id: 'client-123',
  client_secret: 'shh',
  response_type: 'code',
  scope: 'openid email',
  grant_type: 'authorization_code',
  CALLBACK_BASE_URL: `https://${HOST}`,
  CALLBACK_PATH: '/_callback',
  DISCOVERY_DOCUMENT_URL: 'https://idp.example/.well-known/openid-configuration',
  PRIVATE_KEY: sessionPrivate,
  PUBLIC_KEY: sessionPublic,
  SESSION_DURATION: 43200,
  ALLOWED_EMAILS: [ALLOWED],
  JSON_PATH_PREFIXES: ['/api/'],
};

const discovery = {
  issuer: 'https://idp.example',
  authorization_endpoint: 'https://idp.example/authorize',
  token_endpoint: 'https://idp.example/token',
  jwks_uri: 'https://idp.example/jwks',
};

function request(overrides: Partial<CloudFrontRequest> = {}): CloudFrontRequest {
  return {
    clientIp: '203.0.113.1',
    method: 'GET',
    uri: '/admin/',
    querystring: '',
    headers: { host: [{ key: 'Host', value: HOST }] },
    ...overrides,
  } as CloudFrontRequest;
}

function withCookies(req: CloudFrontRequest, cookies: Record<string, string>): CloudFrontRequest {
  const value = Object.entries(cookies)
    .map(([k, v]) => `${k}=${v}`)
    .join('; ');
  req.headers.cookie = [{ key: 'Cookie', value }];
  return req;
}

function sessionToken(subject: string, expiresInSeconds = 43200): string {
  return JsonWebToken.sign({}, sessionPrivate, {
    algorithm: 'RS256',
    audience: HOST,
    subject,
    expiresIn: expiresInSeconds,
  });
}

function idToken(claims: Record<string, unknown>): string {
  return JsonWebToken.sign(claims, idpPrivate, {
    algorithm: 'RS256',
    keyid: 'test-key',
    audience: config.client_id,
    issuer: discovery.issuer,
    expiresIn: 300,
  });
}

function headerOf(response: CloudFrontResultResponse, name: string): string {
  return response.headers?.[name]?.[0]?.value ?? '';
}

function cookiesOf(response: CloudFrontResultResponse): string[] {
  return (response.headers?.['set-cookie'] ?? []).map((c) => c.value);
}

beforeEach(() => {
  __setForTests({ isDevelop: false, config, discovery, jwks: { keys: [idpJwk] } as never });
});

describe('unauthenticated browser request', () => {
  it('redirects to the IdP', async () => {
    const result = await authenticate(request());
    const response = result.response as CloudFrontResultResponse;

    assert.equal(result.authenticated, false);
    assert.equal(response.status, '302');
    assert.ok(headerOf(response, 'location').startsWith(discovery.authorization_endpoint));
  });

  it('sends PKCE, a nonce and a state', async () => {
    const response = (await authenticate(request())).response as CloudFrontResultResponse;
    const params = new URL(headerOf(response, 'location')).searchParams;

    assert.equal(params.get('code_challenge_method'), 'S256');
    assert.ok(params.get('code_challenge'));
    assert.ok(params.get('nonce'));
    assert.ok(params.get('state'));
    assert.equal(params.get('client_id'), config.client_id);
    assert.equal(params.get('redirect_uri'), `https://${HOST}/_callback`);
  });

  it('never puts the raw nonce or verifier in the URL', async () => {
    const response = (await authenticate(request())).response as CloudFrontResultResponse;
    const params = new URL(headerOf(response, 'location')).searchParams;
    const cookies = cookiesOf(response).join('; ');

    const rawNonce = /NONCE=([^;]+)/.exec(cookies)?.[1];
    const rawVerifier = /CODE_VERIFIER=([^;]+)/.exec(cookies)?.[1];

    assert.ok(rawNonce && rawVerifier);
    assert.notEqual(params.get('nonce'), rawNonce);
    assert.equal(params.get('nonce'), hashFromNonce(rawNonce!));
    assert.notEqual(params.get('code_challenge'), rawVerifier);
  });

  it('marks its cookies HttpOnly, Secure and SameSite=Lax', async () => {
    const response = (await authenticate(request())).response as CloudFrontResultResponse;
    for (const cookie of cookiesOf(response)) {
      assert.match(cookie, /HttpOnly/i, cookie);
      assert.match(cookie, /Secure/i, cookie);
      assert.match(cookie, /SameSite=Lax/i, cookie);
    }
  });

  it('keeps the query string in the return path', async () => {
    const response = (await authenticate(request({ uri: '/admin/x', querystring: 'a=1&b=2' })))
      .response as CloudFrontResultResponse;
    const state = new URL(headerOf(response, 'location')).searchParams.get('state')!;
    const returnPath = Buffer.from(state.split('.')[1], 'base64url').toString();
    assert.equal(returnPath, '/admin/x?a=1&b=2');
  });
});

describe('unauthenticated API request', () => {
  it('answers 401 JSON rather than redirecting', async () => {
    // fetch() follows redirects, so a 302 to the IdP would surface as an
    // inscrutable CORS error in the browser.
    const result = await authenticate(request({ uri: '/api/links', method: 'POST' }));
    const response = result.response as CloudFrontResultResponse;

    assert.equal(response.status, '401');
    assert.match(headerOf(response, 'content-type'), /application\/json/);
    assert.equal(JSON.parse(response.body as string).error, 'unauthorized');
  });
});

describe('session cookie', () => {
  it('lets a valid session through to the origin', async () => {
    const req = withCookies(request(), { TOKEN: sessionToken(ALLOWED) });
    const result = await authenticate(req);

    assert.equal(result.authenticated, true);
    assert.equal(result.response, null);
  });

  it('redirects to re-authenticate when the session has expired', async () => {
    // The original rejected inside verifyJwt while its caller tested for
    // `instanceof Error`, so this path used to produce a 500.
    const req = withCookies(request(), { TOKEN: sessionToken(ALLOWED, -10) });
    const response = (await authenticate(req)).response as CloudFrontResultResponse;

    assert.equal(response.status, '302', 'expired sessions must re-authenticate, not error');
    assert.ok(headerOf(response, 'location').startsWith(discovery.authorization_endpoint));
  });

  it('rejects a token signed by someone else', async () => {
    const forged = JsonWebToken.sign({}, idpPrivate, {
      algorithm: 'RS256',
      audience: HOST,
      subject: ALLOWED,
      expiresIn: '12h',
    });
    const response = (await authenticate(withCookies(request(), { TOKEN: forged })))
      .response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('rejects a token minted for another host', async () => {
    const other = JsonWebToken.sign({}, sessionPrivate, {
      algorithm: 'RS256',
      audience: 'someone-else.example',
      subject: ALLOWED,
      expiresIn: '12h',
    });
    const response = (await authenticate(withCookies(request(), { TOKEN: other })))
      .response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('rejects an unsigned token', async () => {
    const unsigned = `${Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString(
      'base64url',
    )}.${Buffer.from(JSON.stringify({ sub: ALLOWED })).toString('base64url')}.`;
    const response = (await authenticate(withCookies(request(), { TOKEN: unsigned })))
      .response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('revokes access as soon as the address leaves the allowlist', async () => {
    // The session is still cryptographically valid; the allowlist is re-checked
    // on every request so removal does not wait for expiry.
    const req = withCookies(request(), { TOKEN: sessionToken('removed@example.com') });
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '403');
  });
});

describe('callback', () => {
  const nonce = randomBytes(32).toString('hex');
  const stateRandom = randomBytes(16).toString('hex');

  function callbackRequest(query: Record<string, string>, cookies: Record<string, string>) {
    return withCookies(
      request({ uri: '/_callback', querystring: new URLSearchParams(query).toString() }),
      cookies,
    );
  }

  function fakeToken(claims: Record<string, unknown>) {
    mock.method(globalThis, 'fetch', async () =>
      new Response(JSON.stringify({ id_token: idToken(claims) }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    );
  }

  const goodCookies = {
    STATE: stateRandom,
    NONCE: nonce,
    CODE_VERIFIER: 'verifier-value',
  };

  it('issues a session and returns to the original path', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/admin/x') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;

    assert.equal(response.status, '302');
    assert.equal(headerOf(response, 'location'), '/admin/x');

    const token = /TOKEN=([^;]+)/.exec(cookiesOf(response).join('; '))?.[1];
    assert.ok(token);
    const decoded = JsonWebToken.verify(token!, sessionPublic, {
      algorithms: ['RS256'],
      audience: HOST,
    }) as JsonWebToken.JwtPayload;
    assert.equal(decoded.sub, ALLOWED);
  });

  it('gives the session cookie the same lifetime as the token', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    const tokenCookie = cookiesOf(response).find((c) => c.startsWith('TOKEN='))!;

    // The original hard-coded Max-Age=60 against a 1 hour token, forcing a
    // fresh login every minute.
    assert.match(tokenCookie, new RegExp(`Max-Age=${config.SESSION_DURATION}\\b`), tokenCookie);
  });

  it('rejects a mismatched state', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(randomBytes(16).toString('hex'), '/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '401', 'login CSRF must be refused');
  });

  it('rejects a missing state cookie', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/') },
      { NONCE: nonce, CODE_VERIFIER: 'verifier-value' },
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('rejects a replayed nonce', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce('some-other-nonce') });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('refuses an address that is not on the allowlist', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({
      email: 'stranger@example.com',
      email_verified: true,
      nonce: hashFromNonce(nonce),
    });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;

    // 403 rather than a redirect: signing in again cannot change the answer,
    // so bouncing back to the IdP would loop forever.
    assert.equal(response.status, '403');
  });

  it('refuses an unverified address', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: false, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '403');
  });

  it('will not redirect off-site via a crafted state', async (t) => {
    t.after(() => mock.restoreAll());
    fakeToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '//evil.example/') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(headerOf(response, 'location'), '/', 'must fall back to the root');
  });

  it('refetches the JWKS when the token uses a key we have not seen', async (t) => {
    t.after(() => mock.restoreAll());

    // Simulate a key rotation: our cache is empty, the IdP now serves the key.
    __setForTests({ jwks: { keys: [] } as never });

    let jwksFetches = 0;
    mock.method(globalThis, 'fetch', async (url: string | URL) => {
      const target = String(url);
      if (target.endsWith('/jwks')) {
        jwksFetches += 1;
        return new Response(JSON.stringify({ keys: [idpJwk] }), {
          headers: { 'content-type': 'application/json' },
        });
      }
      return new Response(
        JSON.stringify({
          id_token: idToken({ email: ALLOWED, email_verified: true, nonce: hashFromNonce(nonce) }),
        }),
        { headers: { 'content-type': 'application/json' } },
      );
    });

    const req = callbackRequest(
      { code: 'auth-code', state: buildState(stateRandom, '/admin') },
      goodCookies,
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;

    assert.equal(response.status, '302', 'rotation must not lock everyone out');
    assert.ok(jwksFetches >= 1, 'should have gone back for the new key');
  });

  it('surfaces an error returned by the IdP', async () => {
    const req = callbackRequest({ error: 'access_denied' }, goodCookies);
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });

  it('rejects a callback with no code', async () => {
    const req = callbackRequest({ state: buildState(stateRandom, '/') }, goodCookies);
    const response = (await authenticate(req)).response as CloudFrontResultResponse;
    assert.equal(response.status, '401');
  });
});

describe('network budget', () => {
  // A viewer-request function is killed at 5 seconds. Fetching the discovery
  // document and JWKS on every cold start is what made it time out, so the
  // common paths must not touch the network at all.

  function countFetches(t: { after: (fn: () => void) => void }) {
    const calls: string[] = [];
    mock.method(globalThis, 'fetch', async (url: string | URL) => {
      calls.push(String(url));
      return new Response('{}', { headers: { 'content-type': 'application/json' } });
    });
    t.after(() => mock.restoreAll());
    return calls;
  }

  it('makes no request when a valid session is presented', async (t) => {
    const calls = countFetches(t);
    const result = await authenticate(withCookies(request(), { TOKEN: sessionToken(ALLOWED) }));

    assert.equal(result.authenticated, true);
    assert.deepEqual(calls, [], 'verifying our own cookie is purely local');
  });

  it('makes no request when answering 401 to an API call', async (t) => {
    const calls = countFetches(t);
    await authenticate(request({ uri: '/api/links' }));
    assert.deepEqual(calls, []);
  });

  it('makes no request when refusing a removed account', async (t) => {
    const calls = countFetches(t);
    const result = await authenticate(
      withCookies(request(), { TOKEN: sessionToken('removed@example.com') }),
    );
    assert.equal((result.response as CloudFrontResultResponse).status, '403');
    assert.deepEqual(calls, []);
  });

  it('does not fetch the discovery document when endpoints are configured', async (t) => {
    const calls = countFetches(t);
    __setForTests({
      config: {
        ...config,
        ISSUER: discovery.issuer,
        AUTHORIZATION_ENDPOINT: discovery.authorization_endpoint,
        TOKEN_ENDPOINT: discovery.token_endpoint,
        JWKS_URI: discovery.jwks_uri,
      },
      discovery: null,
    });

    const response = (await authenticate(request())).response as CloudFrontResultResponse;

    assert.equal(response.status, '302');
    assert.deepEqual(calls, [], 'static endpoints remove the round trip entirely');
  });
});

describe('config loading', () => {
  const validConfigPath = '/tmp/edge-auth-test-config.json';

  it('does not cache a failed load, so a later fix takes effect', async (t) => {
    // This is why populating the Secrets Manager entry after the first deploy
    // works without republishing the function: the failed fetch leaves the
    // cache empty and the next request retries.
    const { writeFileSync, rmSync } = await import('node:fs');
    writeFileSync(validConfigPath, JSON.stringify(config));
    t.after(() => rmSync(validConfigPath, { force: true }));

    __setForTests({ isDevelop: true, config: null, discovery, jwks: { keys: [idpJwk] } as never });

    process.env.LOCAL_CONFIG = '/tmp/definitely-not-here.json';
    const first = await authenticate(request());
    assert.equal((first.response as CloudFrontResultResponse).status, '500');

    process.env.LOCAL_CONFIG = validConfigPath;
    const second = await authenticate(request());
    assert.equal(
      (second.response as CloudFrontResultResponse).status,
      '302',
      'the retry must pick up the now-readable config',
    );

    delete process.env.LOCAL_CONFIG;
    __setForTests({ isDevelop: false });
  });
});

describe('failure handling', () => {
  it('returns 500 without leaking internals when the IdP is unreachable', async (t) => {
    t.after(() => mock.restoreAll());
    mock.method(globalThis, 'fetch', async () => {
      throw new Error('connect ECONNREFUSED 10.0.0.1:443');
    });

    const req = withCookies(
      request({ uri: '/_callback', querystring: `code=x&state=${buildState('a'.repeat(32), '/')}` }),
      { STATE: 'a'.repeat(32), NONCE: 'n', CODE_VERIFIER: 'v' },
    );
    const response = (await authenticate(req)).response as CloudFrontResultResponse;

    assert.equal(response.status, '500');
    assert.ok(!(response.body as string).includes('ECONNREFUSED'));
  });
});
