# url-shortener-aws-serverless

A personal URL shortener on AWS with no servers, no database, and no compute in
the redirect path.

Shortening `https://example.com/some/very/long/path` gives you
`https://your.domain/1a2b3c4d`. Following that link is served entirely by
CloudFront and S3.

```
GET /1a2b3c4d  ──> CloudFront ──> S3 website endpoint ──> 301 to the target
```

Creating links is protected by OIDC single sign-on at the CloudFront edge, so
only addresses you list can shorten anything.

## How it works

Each short link is a **zero-byte S3 object**. The target URL lives in the
object's `x-amz-website-redirect-location` metadata, which the S3 website
endpoint turns into a `301`. The key is the first 40 bits of the SHA-256 of
the URL, as ten hex digits.

There is no database, and the redirect path runs no code of ours — which means
**if the login or the API breaks, existing short links keep working**. That
separation is deliberate and worth preserving if you modify this.

```
                          ┌─────────────────────────────────────┐
   /<hash>  ──────────────┤ (no auth, no edge function)         ├──> S3 website
                          │                                     │    endpoint
   /admin   ──┐           │           CloudFront                │
   /api/*   ──┼─ Lambda@  │                                     ├──> S3 (OAC)
   /_callback─┘  Edge     │                                     ├──> Lambda
                 OIDC     └─────────────────────────────────────┘    Function URL
```

| Component | What it does |
| --- | --- |
| S3 (website endpoint) | Stores the redirect objects |
| CloudFront | Serves redirects, routes the other paths |
| Lambda@Edge | OIDC authorization code flow with PKCE, on viewer requests |
| Lambda (Function URL) | Creates links: hashes, resolves collisions, writes to S3 |
| S3 (private, OAC) | Serves the one-page admin form |

## What it costs

For personal use this lands within or near the AWS free tier. The dominant
cost is CloudFront requests; S3 storage is negligible because every object is
empty. Secrets Manager is about $0.40/month for the one secret.

## Requirements

- An AWS account, and Terraform 1.10 or newer
- A domain you control, and an **ACM certificate in us-east-1** covering it
- Node.js 20+ and Python 3.11+ for the two functions
- An OIDC provider. Google is what the defaults assume

DNS can live anywhere — you just point a `CNAME` at the CloudFront
distribution. Nothing here manages DNS for you.

## Quickstart

```bash
git clone https://github.com/komazarari/url-shortener-aws-serverless
cd url-shortener-aws-serverless
```

1. **Create an OAuth client** at your IdP. For Google, add
   `https://your.domain/_callback` as an authorized redirect URI.

2. **Create a state bucket** by hand, then point Terraform at it:

   ```bash
   cp terraform/backend.hcl.example terraform/backend.hcl
   $EDITOR terraform/backend.hcl
   ```

3. **Fill in your values:**

   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   $EDITOR terraform/terraform.tfvars   # domain, certificate ARN, bucket names
   openssl rand -hex 32                 # paste into origin_secret
   ```

4. **Build the edge function:**

   ```bash
   cd functions/edge-auth
   cp .example.SM_CONFIG_KEY.json SM_CONFIG_KEY.json
   npm ci && npm test && npm run build
   cd ../..
   ```

5. **Apply:**

   ```bash
   cd terraform
   terraform init -backend-config=backend.hcl
   terraform apply
   ```

6. **Populate the OIDC config.** Terraform creates the Secrets Manager entry
   but never sees its contents, so no client secret or signing key enters
   Terraform state:

   ```bash
   ./scripts/edge-auth-config.sh build   # prompts; generates a signing keypair
   ./scripts/edge-auth-config.sh push
   ```

7. **Point DNS** at the distribution:

   ```
   your.domain  CNAME  dxxxxxxxxxxxxx.cloudfront.net
   ```

   If you use Cloudflare, keep this **DNS-only** (grey cloud). Proxying stacks
   a second CDN in front of CloudFront and breaks request signing.

8. Open `https://your.domain/admin` and shorten something.

Detailed steps, verification commands and troubleshooting live in
[`docs/`](docs/).

## Verifying it

```bash
./scripts/verify-plan.sh          # what a terraform apply would actually change
./scripts/verify-origin-lock.sh   # the bucket cannot be reached directly
./scripts/diagnose-edge-auth.sh   # every Lambda@Edge restriction, checked
```

```bash
cd functions/api        && python3 -m unittest   # 54 tests, no dependencies
cd functions/edge-auth  && npm test              # 65 tests
```

## Known limitations

Stated plainly, because some of these are inherent rather than unfinished.

- **Redirects are `301` and browsers cache them hard.** Once a key is handed
  out, changing where it points will not reach anyone who already followed it.
  Treat short links as immutable.
- **The redirect bucket must allow anonymous reads.** The S3 website endpoint
  is the only thing that turns the metadata into a `301`, and it does not
  support OAC. Access is gated on a secret `Referer` that CloudFront injects —
  effective obfuscation with a high-entropy value, but not a cryptographic
  boundary. Do not shorten URLs that are themselves secrets.
- **Keys are derived from the URL, not random.** 40 bits is too wide to sweep,
  but anyone who already suspects a target can hash it and check whether you
  shortened it. Fine for links you would share anyway; not fine for anything
  confidential.
- **No click tracking, no expiry, no custom aliases.** Adding them is
  straightforward; none are implemented.
- **Lambda@Edge replicas take hours to delete.** Expect `terraform destroy` to
  fail for a while after removing the edge function.

## Documentation

| Document | Contents |
| --- | --- |
| [`docs/design.md`](docs/design.md) | Architecture and the reasoning behind it |
| [`docs/setup.md`](docs/setup.md) | Full setup, in order, with verification at each step |
| [`docs/operations.md`](docs/operations.md) | Rotating secrets, changing the allowlist, troubleshooting |

## License

MIT. See [LICENSE](LICENSE).
