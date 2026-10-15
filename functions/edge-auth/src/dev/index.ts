/**
 * Local development server.
 *
 * Wraps authenticate() in Express so the full OIDC round trip can be exercised
 * against the real IdP before anything is deployed to Lambda@Edge -- where
 * iteration costs a CloudFront propagation each time.
 *
 *   cp .example.LOCAL_CONFIG.json LOCAL_CONFIG.json   # fill it in
 *   npm run dev
 *   open http://localhost:3000/admin/
 *
 * Register http://localhost:3000/_callback as a redirect URI at the IdP.
 */

process.env.IS_DEVELOP = '1';

import express, { type NextFunction, type Request, type Response } from 'express';
import type { CloudFrontHeaders, CloudFrontRequest, CloudFrontResultResponse } from 'aws-lambda';
import { authenticate } from '../auth.js';

const port = Number(process.env.PORT ?? 3000);
const app = express();

function toCloudFrontRequest(req: Request): CloudFrontRequest {
  const headers: CloudFrontHeaders = {};
  for (const [key, raw] of Object.entries(req.headers)) {
    if (raw === undefined) continue;
    const value = Array.isArray(raw) ? raw.join(',') : String(raw);
    headers[key.toLowerCase()] = [{ key, value }];
  }

  const [uri, querystring = ''] = req.originalUrl.split('?');
  return {
    clientIp: req.ip ?? '127.0.0.1',
    method: req.method,
    uri,
    querystring,
    headers,
  } as CloudFrontRequest;
}

function send(res: Response, cf: CloudFrontResultResponse): void {
  res.status(Number(cf.status));

  for (const [name, values] of Object.entries(cf.headers ?? {})) {
    if (name === 'set-cookie') {
      // Pass the serialised cookie through verbatim rather than re-parsing it,
      // so what the browser sees matches what CloudFront would send.
      res.setHeader('Set-Cookie', values.map((v) => v.value));
    } else {
      res.setHeader(values[0].key ?? name, values[0].value);
    }
  }

  res.send(cf.body ?? '');
}

app.use(async (req: Request, res: Response, next: NextFunction) => {
  try {
    const result = await authenticate(toCloudFrontRequest(req));
    if (result.authenticated) return next();
    if (!result.response) {
      res.status(500).send('auth returned neither a pass nor a response');
      return;
    }
    send(res, result.response as CloudFrontResultResponse);
  } catch (err) {
    console.error(err);
    res.status(500).send('Internal Server Error');
  }
});

// Stand-ins for the real origins.
app.get('/api/*splat', (req, res) => {
  res.json({ ok: true, note: 'the API origin would answer here', path: req.path });
});

app.use((req, res) => {
  res.type('html').send(`<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Signed in</title></head>
<body>
  <h1>Signed in</h1>
  <p>You reached <code>${req.path}</code>, so authentication passed.</p>
  <p><a href="/api/links">Try the API path</a></p>
</body></html>`);
});

app.listen(port, () => {
  console.log(`dev server on http://localhost:${port}`);
  console.log('config: LOCAL_CONFIG.json (CALLBACK_BASE_URL must match this origin)');
});
