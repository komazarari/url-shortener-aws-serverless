import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  buildState,
  constantTimeEquals,
  getCookieValue,
  hashFromNonce,
  isAllowedEmail,
  isSafeReturnPath,
  parseState,
  safeReturnPathOrRoot,
  wantsJsonResponse,
} from '../src/auth.js';
import { validateConfig } from '../src/config.js';

describe('isAllowedEmail', () => {
  const allowed = ['You@Example.com', 'other@example.org'];

  it('accepts a verified address on the list', () => {
    assert.equal(isAllowedEmail({ email: 'you@example.com', email_verified: true }, allowed), true);
  });

  it('is case insensitive on both sides', () => {
    assert.equal(isAllowedEmail({ email: 'YOU@EXAMPLE.COM', email_verified: true }, allowed), true);
  });

  it('tolerates surrounding whitespace', () => {
    assert.equal(isAllowedEmail({ email: ' you@example.com ', email_verified: true }, allowed), true);
  });

  it('rejects an address that is not on the list', () => {
    assert.equal(isAllowedEmail({ email: 'nope@example.com', email_verified: true }, allowed), false);
  });

  it('rejects an unverified address', () => {
    // Anyone can put an address they do not control on an account.
    assert.equal(isAllowedEmail({ email: 'you@example.com', email_verified: false }, allowed), false);
    assert.equal(isAllowedEmail({ email: 'you@example.com' }, allowed), false);
  });

  it('accepts the string "true", which some IdPs send', () => {
    assert.equal(isAllowedEmail({ email: 'you@example.com', email_verified: 'true' }, allowed), true);
  });

  it('rejects a missing or non-string email', () => {
    assert.equal(isAllowedEmail({ email_verified: true }, allowed), false);
    assert.equal(isAllowedEmail({ email: '', email_verified: true }, allowed), false);
    assert.equal(isAllowedEmail({ email: 42, email_verified: true }, allowed), false);
  });

  it('rejects everyone when the list is empty', () => {
    assert.equal(isAllowedEmail({ email: 'you@example.com', email_verified: true }, []), false);
  });

  it('does not match on a substring', () => {
    assert.equal(
      isAllowedEmail({ email: 'you@example.com.evil.test', email_verified: true }, allowed),
      false,
    );
  });
});

describe('state', () => {
  it('round-trips the return path', () => {
    const random = 'a'.repeat(32);
    const parsed = parseState(buildState(random, '/admin/index.html?x=1'));
    assert.deepEqual(parsed, { random, returnPath: '/admin/index.html?x=1' });
  });

  it('survives paths containing dots', () => {
    const random = 'b'.repeat(32);
    const parsed = parseState(buildState(random, '/a.b.c/d.html'));
    assert.equal(parsed?.returnPath, '/a.b.c/d.html');
  });

  it('handles non-ASCII paths', () => {
    // Two-byte and three-byte UTF-8 sequences, since state is base64url encoded.
    const random = 'c'.repeat(32);
    const path = '/ünicode/日本語';
    assert.equal(parseState(buildState(random, path))?.returnPath, path);
  });

  it('rejects malformed values', () => {
    for (const value of [undefined, null, 42, '', 'nodot', '.onlyencoded', 'short.aGk=']) {
      assert.equal(parseState(value), null, `expected null for ${JSON.stringify(value)}`);
    }
  });
});

describe('isSafeReturnPath', () => {
  it('accepts ordinary absolute paths', () => {
    for (const path of ['/', '/admin/', '/admin/index.html?a=1#f']) {
      assert.equal(isSafeReturnPath(path), true, path);
    }
  });

  it('rejects protocol-relative URLs', () => {
    // Browsers treat //evil.example as absolute, which would turn the login
    // flow itself into an open redirect.
    assert.equal(isSafeReturnPath('//evil.example/'), false);
  });

  it('rejects absolute URLs', () => {
    assert.equal(isSafeReturnPath('https://evil.example/'), false);
    assert.equal(isSafeReturnPath('javascript:alert(1)'), false);
  });

  it('rejects backslashes, which some browsers fold to slashes', () => {
    assert.equal(isSafeReturnPath('/\\evil.example'), false);
  });

  it('rejects control characters used for header smuggling', () => {
    assert.equal(isSafeReturnPath('/ok\r\nSet-Cookie: a=b'), false);
    assert.equal(isSafeReturnPath('/ok\nX: y'), false);
  });

  it('rejects empty and relative paths', () => {
    assert.equal(isSafeReturnPath(''), false);
    assert.equal(isSafeReturnPath('admin'), false);
  });

  it('falls back to the root for anything unsafe', () => {
    assert.equal(safeReturnPathOrRoot('//evil.example/'), '/');
    assert.equal(safeReturnPathOrRoot('/admin/'), '/admin/');
  });
});

describe('wantsJsonResponse', () => {
  it('matches the API prefix', () => {
    assert.equal(wantsJsonResponse('/api/links'), true);
    assert.equal(wantsJsonResponse('/api/links/1a2b3c4d'), true);
  });

  it('does not match browser paths', () => {
    assert.equal(wantsJsonResponse('/admin/'), false);
    assert.equal(wantsJsonResponse('/1a2b3c4d'), false);
  });

  it('does not match a path that merely starts with the same letters', () => {
    assert.equal(wantsJsonResponse('/apiary'), false);
  });

  it('honours a custom prefix list', () => {
    assert.equal(wantsJsonResponse('/rpc/x', ['/rpc/']), true);
    assert.equal(wantsJsonResponse('/api/x', ['/rpc/']), false);
  });
});

describe('constantTimeEquals', () => {
  it('compares equal strings', () => {
    assert.equal(constantTimeEquals('abc', 'abc'), true);
  });

  it('rejects different strings of the same length', () => {
    assert.equal(constantTimeEquals('abc', 'abd'), false);
  });

  it('rejects different lengths without throwing', () => {
    assert.equal(constantTimeEquals('abc', 'abcd'), false);
    assert.equal(constantTimeEquals('', 'a'), false);
  });
});

describe('getCookieValue', () => {
  const headers = { cookie: [{ key: 'Cookie', value: 'A=1; TOKEN=abc; B=2' }] };

  it('finds a cookie', () => {
    assert.equal(getCookieValue(headers as never, 'TOKEN'), 'abc');
  });

  it('returns null when absent', () => {
    assert.equal(getCookieValue(headers as never, 'NOPE'), null);
    assert.equal(getCookieValue({} as never, 'TOKEN'), null);
  });

  it('searches every Cookie header CloudFront supplies', () => {
    const split = {
      cookie: [
        { key: 'Cookie', value: 'A=1' },
        { key: 'Cookie', value: 'TOKEN=xyz' },
      ],
    };
    assert.equal(getCookieValue(split as never, 'TOKEN'), 'xyz');
  });
});

describe('hashFromNonce', () => {
  it('is deterministic', () => {
    assert.equal(hashFromNonce('abc'), hashFromNonce('abc'));
  });

  it('differs per nonce and never leaks it', () => {
    const hash = hashFromNonce('secret-nonce');
    assert.notEqual(hash, hashFromNonce('other-nonce'));
    assert.ok(!hash.includes('secret-nonce'));
  });
});

describe('validateConfig', () => {
  const base = {
    client_id: 'id',
    client_secret: 'secret',
    response_type: 'code',
    scope: 'openid email',
    grant_type: 'authorization_code',
    CALLBACK_BASE_URL: 'https://example.net',
    CALLBACK_PATH: '/_callback',
    DISCOVERY_DOCUMENT_URL: 'https://idp.example/.well-known/openid-configuration',
    PRIVATE_KEY: 'k',
    PUBLIC_KEY: 'k',
    SESSION_DURATION: 3600,
    ALLOWED_EMAILS: ['you@example.com'],
  };

  it('accepts a complete config', () => {
    assert.equal(validateConfig({ ...base }).client_id, 'id');
  });

  it('reports every missing key at once', () => {
    const { client_id, PUBLIC_KEY, ...rest } = base;
    assert.throws(() => validateConfig(rest as never), /client_id.*PUBLIC_KEY|PUBLIC_KEY.*client_id/s);
  });

  it('refuses an empty allowlist', () => {
    // Otherwise the service authenticates everyone and authorises no one,
    // which looks like a mysterious 403 rather than a config error.
    assert.throws(() => validateConfig({ ...base, ALLOWED_EMAILS: [] }), /non-empty/);
  });

  it('refuses entries that are not email addresses', () => {
    assert.throws(() => validateConfig({ ...base, ALLOWED_EMAILS: ['example.com'] }), /email/);
  });
});
