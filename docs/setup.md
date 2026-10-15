# Setup

Start to finish, in the order that works. Roughly an hour, most of it waiting
for CloudFront.

## Why this order

Three dependencies dictate the sequence, and getting them wrong wastes a
CloudFront propagation cycle each time.

**The edge function's secret name is baked in at build time.** Lambda@Edge
cannot use environment variables, so the Secrets Manager entry it reads is
compiled into the bundle. Build before you apply, and keep the name in sync.

**Terraform creates the secret but never its contents.** The client secret and
session signing key are pushed separately, which keeps them out of Terraform
state. So the first apply produces a function that fails until step 6.

**CloudFront changes take minutes to propagate; S3 and IAM are immediate.**
Anything that tightens access has to go second, after the thing that grants it
has reached every edge location.

## Prerequisites

- Terraform 1.10+ (for S3 native state locking), AWS CLI v2, `jq`, `openssl`
- Node.js 20+, Python 3.11+
- A domain, and an **ACM certificate in us-east-1** covering it, status ISSUED
- Admin-ish AWS credentials. Lambda@Edge needs `iam:CreateServiceLinkedRole`
  the first time

```bash
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='your.domain']"
```

CloudFront only accepts certificates from us-east-1, whatever region the rest
of your infrastructure uses.

---

## 1. Create the OIDC client

For Google, at <https://console.cloud.google.com/apis/credentials>:

- Application type: **Web application**
- Authorized redirect URI: `https://your.domain/_callback`

Add `http://localhost:3000/_callback` too if you want to use the local
development server.

Keep the client ID and secret to hand. You will paste them in step 6, and the
secret is never echoed or written to shell history.

## 2. Create the state bucket

Terraform cannot manage the bucket holding its own state, so make it by hand.

```bash
BUCKET=tfstate-$(aws sts get-caller-identity --query Account --output text)-$RANDOM

aws s3api create-bucket --bucket "$BUCKET" --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

cp terraform/backend.hcl.example terraform/backend.hcl
$EDITOR terraform/backend.hcl
```

Versioning matters: it is your only way back from a corrupted state file.

`backend.tf` holds an empty `backend "s3" {}` block and is committed; the
values live in the gitignored `backend.hcl`. The empty block is load-bearing —
without it, `terraform init` silently falls back to local state.

## 3. Fill in the variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars
openssl rand -hex 32          # paste into origin_secret
```

| Variable | Notes |
| --- | --- |
| `domain_name` | The short-link domain |
| `acm_certificate_arn` | From the prerequisites. us-east-1 |
| `redirect_bucket_name` | Holds the redirect objects. **Globally unique** — it becomes an S3 website endpoint hostname |
| `admin_bucket_name` | Prefix only; account id and region are appended |
| `origin_secret` | 32+ random bytes. Never seen by browsers |
| `enforce_origin_secret` | Leave `true` for a fresh install |

`enforce_origin_secret` exists for retrofitting an already-running service,
where the bucket policy has to be tightened only after CloudFront has started
sending the header. Building from scratch, both sides appear at once.

## 4. Build the edge function

```bash
cd functions/edge-auth
cp .example.SM_CONFIG_KEY.json SM_CONFIG_KEY.json
$EDITOR SM_CONFIG_KEY.json     # must match terraform's edge_auth_secret_name
npm ci && npm test && npm run build
cd ../..
```

The build prints the bundle size and fails if it approaches the **1 MB limit
for viewer-request Lambda@Edge**. It should come out around 80 KB zipped.

If `SecretsManagerKey` and `edge_auth_secret_name` disagree, the function reads
the wrong secret and reports `AccessDeniedException` from an edge replica —
hard to trace. `scripts/edge-auth-config.sh` cross-checks them and refuses to
run on a mismatch.

## 5. First apply

```bash
cd terraform
terraform init -backend-config=backend.hcl
../scripts/verify-plan.sh
terraform apply
```

`verify-plan.sh` lists which attributes actually change and stops if anything
would be created or destroyed unexpectedly. Worth reading before every apply.

This takes a while: attaching a Lambda@Edge function makes CloudFront deploy to
every edge location.

**`/admin` returns 500 at this point.** The secret exists but is empty. That is
expected, and step 6 fixes it without another apply — a failed config load is
not cached, so the next request picks up the new value.

## 6. Push the OIDC config

```bash
./scripts/edge-auth-config.sh build
```

Prompts for the client ID and secret, the allowed email addresses, and the
session lifetime; generates an RSA keypair for signing session cookies. The
domain and callback path default to what Terraform reports, so the redirect URI
cannot drift from the behaviour that serves it.

```bash
./scripts/edge-auth-config.sh push
```

Validates the config, uploads it base64-encoded, and offers to delete the local
plaintext copy.

```bash
./scripts/edge-auth-config.sh show    # secrets redacted
```

## 7. Point DNS at CloudFront

```bash
terraform -chdir=terraform output -raw cloudfront_distribution_id
aws cloudfront get-distribution --id <ID> --query Distribution.DomainName --output text
```

Create a `CNAME` from your domain to that hostname. Nothing here manages DNS.

**Using Cloudflare? Keep it DNS-only (grey cloud).** Proxying puts a second CDN
in front of CloudFront: two TLS terminations, two caches for a `301` you
already cannot revoke, and interference with request signing.

## 8. Verify

Work outward from the parts with the fewest moving pieces.

```bash
# The redirect path — no auth, no code
curl -sI https://your.domain/ | head -3

# The bucket is not reachable directly, and nothing proxies in front of CloudFront
DOMAIN=your.domain BUCKET=your-redirect-bucket KEY=<existing-key> \
  ./scripts/verify-origin-lock.sh

# The API refuses unauthenticated callers before reaching Lambda
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://your.domain/api/links \
  -H 'content-type: application/json' -d '{"url":"https://example.com/"}'
#   401

# Sign-in redirects to the IdP
curl -sI https://your.domain/admin | head -3
#   HTTP/2 302
#   location: https://accounts.google.com/...
```

Then open `https://your.domain/admin` in a browser, sign in, shorten a URL, and
follow the result.

An account outside the allowlist should get **403**, not a login loop —
signing in again cannot change the answer, so bouncing back to the IdP would
spin forever.

## When something is wrong

See [operations.md](operations.md), which is organised by symptom. The two
diagnostics worth knowing now:

```bash
./scripts/diagnose-edge-auth.sh    # checks every documented Lambda@Edge restriction

# Lambda@Edge logs go to the region nearest the viewer, NOT us-east-1
aws logs tail /aws/lambda/us-east-1.url-shortener-edge-auth \
  --region ap-northeast-1 --follow
```
