# Operations

Routine changes, and what to do when something breaks.

## Where the logs are

**Lambda@Edge logs do not go to the region the function lives in.** The
function is in us-east-1; its replicas log wherever the viewer connected.

```bash
# Viewer in Tokyo -> ap-northeast-1, despite the us-east-1. prefix in the name
aws logs tail /aws/lambda/us-east-1.url-shortener-edge-auth \
  --region ap-northeast-1 --follow
```

The registration API is an ordinary Lambda and logs where you would expect:

```bash
aws logs tail /aws/lambda/url-shortener-api --follow
```

## Changing who can sign in

No redeploy needed.

```bash
./scripts/edge-auth-config.sh build   # re-enter values, adjust the address list
./scripts/edge-auth-config.sh push
```

Config is cached per execution environment for 15 minutes, so a change reaches
every replica within that window. Removal takes effect on the next request
after that: the allowlist is re-checked on every request rather than trusted
for the lifetime of an issued session.

To confirm what is currently stored:

```bash
./scripts/edge-auth-config.sh show
```

## Rotating the origin secret

The secret CloudFront puts in the `Referer` header, which the redirect bucket's
policy requires. Rotate in two steps, because the bucket policy applies
instantly while CloudFront takes minutes to propagate.

1. Set the new `origin_secret` **and** `enforce_origin_secret = false`, then
   apply. The policy relaxes, so both old and new replicas keep working.
2. Wait for the distribution to report `Deployed`.
3. Set `enforce_origin_secret = true` and apply.

There is a window in step 1 where the bucket is readable without the header. To
avoid it, make the policy condition accept both values first and drop the old
one afterwards — a three-step version of the same idea.

Rolling back is fast in either direction: `enforce_origin_secret = false` plus
an apply restores service immediately, with no CloudFront change involved.

```bash
DOMAIN=your.domain BUCKET=your-redirect-bucket KEY=<existing-hash> \
  ./scripts/verify-origin-lock.sh
```

## Rotating the session signing key

`edge-auth-config.sh build` generates a fresh keypair every time, so pushing a
new config invalidates every existing session. Users sign in again; nothing
else is affected.

## Certificate renewal

ACM renews automatically **only while the DNS validation record still exists**.
Deleting the `_….your.domain` CNAME after issuance breaks renewal silently, and
you find out when the certificate expires and every short link stops resolving.

Check a month before expiry:

```bash
aws acm describe-certificate --region us-east-1 \
  --certificate-arn <arn> --query 'Certificate.[Status,NotAfter,RenewalEligibility]'
```

## Deploying code changes

```bash
# Registration API
cd functions/api && python3 -m unittest && cd ../..
cd terraform && ../scripts/verify-plan.sh && terraform apply

# Edge function
cd functions/edge-auth && npm test && npm run build && cd ../..
cd terraform && ../scripts/verify-plan.sh && terraform apply
```

Editing the edge function publishes a new version and updates the CloudFront
association, which means another propagation wait.

**Comment-only changes do not redeploy.** esbuild's minifier strips comments,
so the bundle is byte-identical and `source_code_hash` does not move. This is
correct behaviour, and config changes never needed a redeploy anyway.

---

## Troubleshooting

### 503, no logs anywhere

The function never ran; replication failed. The message does not say which
precondition was violated.

```bash
./scripts/diagnose-edge-auth.sh
```

Checks runtime, architecture (arm64 is unsupported), memory (≤128 MB for viewer
events), timeout (≤5 s), absence of environment variables and layers, package
size, runtime management mode, **whether the execution role trusts
`edgelambda.amazonaws.com`**, and whether CloudFront points at a version that
exists.

If everything passes, it is usually IAM propagation — the role, the function
and the association were created in one apply and CloudFront validated before
the trust policy had settled. Republish and reattach:

```bash
cd functions/edge-auth && npm run build && cd ../../terraform && terraform apply
```

### `Status: timeout` in the logs

The function ran and used its whole 5-second budget, which means a network call
hung. On the common paths it makes none: verifying a session cookie is local,
and an unauthenticated API call is answered without contacting the IdP. Suspect
reachability to Secrets Manager.

Every outbound call has a 2-second timeout and logs its duration, so the log
identifies which one:

```
config loaded in 320ms
GET https://... took 180ms
```

Supplying `ISSUER`, `AUTHORIZATION_ENDPOINT`, `TOKEN_ENDPOINT` and `JWKS_URI`
in the config removes the discovery fetch entirely.

### `/admin` returns 500

Config missing or invalid. Read the logs; `missing required config keys` means
rebuild it with `edge-auth-config.sh build`. `AccessDeniedException` means the
secret name in `SM_CONFIG_KEY.json` disagrees with Terraform.

### `/admin` loops back to the IdP

Cookies are not being kept. Check that the callback set `Secure` (it is
disabled only for the local dev server) and that clocks are not badly skewed.

### 403 after signing in

The account is not on the allowlist. Working as intended.

### API returns 403 `Forbidden. For troubleshooting Function URL authorization...`

The Lambda resource policy is missing `lambda:InvokeFunction`. Function URLs
created from October 2025 onward require **both** that and
`lambda:InvokeFunctionUrl`.

The confusing part: signing requests directly keeps working, because an admin
principal carries both permissions in its identity policy. "Direct calls work,
CloudFront gets 403" is the signature of this one.

```bash
aws lambda get-policy --function-name url-shortener-api \
  --query Policy --output text | jq -r '.Statement[] | "\(.Sid)\t\(.Action)"'
```

Both statements are defined in `terraform/lambda_api.tf`. Do not delete either.

### API returns 403 `SignatureDoesNotMatch`

The browser did not send `x-amz-content-sha256`, or its value does not match
the body. Lambda rejects unsigned payloads, so the caller must hash the body
itself. `web/admin.html` does this with `crypto.subtle.digest`.

### API returns 500

Check the API logs. If it says `s3:ListBucket`, see below.

---

## Do not change these

Each of these looks removable and is not.

**`s3:ListBucket` on the API's execution role.** There is no listing endpoint,
so it reads as surplus. But without it, `HeadObject` on a key that does not
exist returns 403 instead of 404 — S3 hides existence from callers who cannot
list. Collision resolution asks "is this key free?" on every request, so it
fails on the first lookup.

**`include_body = false` on the `/api/*` edge association.** If the edge
function received and re-emitted the body, the hash the browser computed would
no longer match what OAC signs.

**The absence of an edge function on the default cache behaviour.** Keeping the
redirect path free of code is what makes existing short links survive an
authentication outage.

**`Managed-AllViewerExceptHostHeader` on `/api/*`.** It forwards
`x-amz-content-sha256`. Excluding `Host` is also required: SigV4 must sign the
origin's hostname, not the viewer's.

**`prevent_destroy` on the redirect bucket.** Recreating it destroys every
short link ever issued.
