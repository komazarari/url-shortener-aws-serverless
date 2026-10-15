#!/usr/bin/env bash
#
# verify-origin-lock.sh - check that the redirect bucket is only reachable
#                         through CloudFront
#
# Three things:
#   1. redirects still work through CloudFront          -> 301
#   2. the S3 website endpoint refuses direct callers   -> 403
#   3. nothing is proxying in front of CloudFront
#
# Usage:
#   DOMAIN=your.domain \
#   BUCKET=your-redirect-bucket \
#   KEY=1a2b3c4d \
#   ./scripts/verify-origin-lock.sh
#
# KEY is an existing short key. Without it the script probes a key that cannot
# exist, so CloudFront should answer 404 while direct access is still 403.
#
set -euo pipefail

DOMAIN="${DOMAIN:-}"
BUCKET="${BUCKET:-}"
REGION="${REGION:-ap-northeast-1}"
KEY="${KEY:-}"

if [[ -z "$DOMAIN" || -z "$BUCKET" ]]; then
  echo "DOMAIN and BUCKET are required." >&2
  echo "  DOMAIN=your.domain BUCKET=your-bucket KEY=1a2b3c4d $0" >&2
  exit 2
fi

WEBSITE_ENDPOINT="${BUCKET}.s3-website-${REGION}.amazonaws.com"

# Cache-bust, so a stored response cannot mask the current configuration.
BUST="__verify_$(date +%s)_$$"

if [[ -n "$KEY" ]]; then
  CF_URL="https://${DOMAIN}/${KEY}?${BUST}"
  S3_URL="http://${WEBSITE_ENDPOINT}/${KEY}"
  EXPECT_CF="301"
else
  CF_URL="https://${DOMAIN}/__nonexistent_${BUST}"
  S3_URL="http://${WEBSITE_ENDPOINT}/__nonexistent_${BUST}"
  EXPECT_CF="404"
  echo "note: no KEY given, probing a nonexistent key (expecting 404 via CloudFront)"
  echo
fi

# One request per target. Asking twice risks reporting a status from one
# response and a Location from another, which is exactly the kind of
# inconsistency a diagnostic must not introduce.
probe() {
  curl -sSI --max-time 15 -w '\nHTTP_CODE=%{http_code}\n' "$1" 2>/dev/null || true
}
status_from() { sed -n 's/^HTTP_CODE=//p' <<<"$1" | tail -1; }
header_from() {
  awk -v want="$(tr '[:upper:]' '[:lower:]' <<<"$2")" \
    'BEGIN{FS=": "} tolower($1)==want {sub(/\r$/,"",$2); print $2; exit}' <<<"$1"
}

echo "== 1. through CloudFront =="
echo "   $CF_URL"
cf_response=$(probe "$CF_URL")
cf_status=$(status_from "$cf_response")
cf_loc=$(header_from "$cf_response" "location")
echo "   HTTP ${cf_status:-000} ${cf_loc:+-> $cf_loc}"
cf_status="${cf_status:-000}"
if [[ "$cf_status" == "$EXPECT_CF" ]]; then
  echo "   OK: as expected ($EXPECT_CF)"
  cf_ok=1
elif [[ "$cf_status" == "403" ]]; then
  echo "   BROKEN: CloudFront is being refused by S3."
  echo "           Set enforce_origin_secret = false and apply to restore service."
  cf_ok=0
else
  echo "   UNEXPECTED: wanted $EXPECT_CF, got $cf_status"
  cf_ok=0
fi

echo
echo "== 2. straight at the S3 website endpoint =="
echo "   $S3_URL"
s3_status=$(status_from "$(probe "$S3_URL")")
s3_status="${s3_status:-000}"
echo "   HTTP $s3_status"
case "$s3_status" in
  403) echo "   OK: direct access is refused"; s3_ok=1 ;;
  301) echo "   NOT APPLIED: the bucket is serving redirects to anyone."
       echo "                Set enforce_origin_secret = true and apply."; s3_ok=0 ;;
  404) echo "   NOT APPLIED: expected 403. The policy condition is not in effect."; s3_ok=0 ;;
  *)   echo "   UNEXPECTED: $s3_status"; s3_ok=0 ;;
esac

echo
echo "== 3. path to the origin =="
hdrs=$(probe "https://${DOMAIN}/")
if grep -qi '^server:.*cloudflare' <<<"$hdrs"; then
  cat <<'WARN'
   PROBLEM: a proxying CDN sits in front of CloudFront.

   Stacking CDNs gives you two TLS terminations, two caches for a 301 you
   cannot revoke, and interference with request signing. Set this DNS record
   to DNS-only (grey cloud on Cloudflare).
WARN
  path_ok=0
elif grep -qi '^x-amz-cf-id:' <<<"$hdrs" || grep -qi '^via:.*cloudfront' <<<"$hdrs"; then
  pop=$(grep -i '^x-amz-cf-pop:' <<<"$hdrs" | tr -d '\r' | awk '{print $2}')
  echo "   OK: reaching CloudFront directly${pop:+ (PoP: $pop)}"
  path_ok=1
else
  echo "   INCONCLUSIVE. Response headers:"
  echo "$hdrs" | grep -iE '^(server|via|x-amz)' | sed 's/^/     /'
  path_ok=1
fi

echo
echo "=================================================="
if [[ $cf_ok -eq 1 && $s3_ok -eq 1 && $path_ok -eq 1 ]]; then
  echo " OK - redirects work, direct access is blocked"
  exit 0
else
  echo " NOT OK - see above"
  exit 1
fi
