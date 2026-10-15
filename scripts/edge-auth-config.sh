#!/usr/bin/env bash
#
# edge-auth-config.sh - build the OIDC config and push it to Secrets Manager
#
# Lambda@Edge cannot use environment variables, so its settings live as a
# base64-encoded JSON blob in a Secrets Manager entry in us-east-1.
#
# Usage:
#   ./scripts/edge-auth-config.sh build    # create CF_CONFIG.json interactively
#   ./scripts/edge-auth-config.sh push     # upload it, then delete the local copy
#   ./scripts/edge-auth-config.sh show     # print what is currently stored (secrets redacted)
#
# The client secret and signing key are prompted for rather than passed as
# arguments, so they stay out of shell history and the process list.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$HERE/../functions/edge-auth"
TF_DIR="$HERE/../terraform"
CONFIG_FILE="$EDGE_DIR/CF_CONFIG.json"

# Duplicated verbatim in diagnose-edge-auth.sh. These are standalone operator
# scripts meant to be runnable and copyable on their own, so a shared library
# would buy less than it costs in sourcing failures. Keep the two identical.
tf_output() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

# The secret name has to agree in three places, and a mismatch only shows up as
# an opaque AccessDenied from an edge replica. Terraform is the source of truth.
resolve_secret_name() {
  local from_tf from_bundle
  from_tf="$(tf_output edge_auth_secret_name)"
  SECRET_NAME="${SECRET_NAME:-${from_tf:-url-shortener/edge-auth-config}}"

  if [[ -f "$EDGE_DIR/SM_CONFIG_KEY.json" ]] && command -v jq >/dev/null 2>&1; then
    from_bundle="$(jq -r '.SecretsManagerKey // empty' "$EDGE_DIR/SM_CONFIG_KEY.json")"
    if [[ -n "$from_bundle" && "$from_bundle" != "$SECRET_NAME" ]]; then
      cat >&2 <<EOS
Secret name mismatch:
  terraform (edge_auth_secret_name) : ${from_tf:-<unavailable>}
  bundle    (SM_CONFIG_KEY.json)    : $from_bundle
  using                             : $SECRET_NAME

The bundled name is baked in at build time, so the function would read the
wrong secret. Make them match, then rebuild:
  cd functions/edge-auth && npm run build
EOS
      exit 1
    fi
  fi
}

case "${1:-}" in
  build | push | show) ;;
  *)
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }
}
require jq
require openssl
[[ "$1" == "build" ]] || require aws

resolve_secret_name
echo "secret: $SECRET_NAME"
echo

# ---------------------------------------------------------------------------

if [[ "$1" == "show" ]]; then
  aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" --region us-east-1 \
    --query SecretString --output text |
    jq -r .config | base64 --decode |
    jq '.client_secret = "<redacted>" | .PRIVATE_KEY = "<redacted>" | .PUBLIC_KEY = (.PUBLIC_KEY | .[0:40] + "...")'
  exit 0
fi

if [[ "$1" == "push" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { echo "$CONFIG_FILE not found. Run 'build' first." >&2; exit 1; }

  # Fail before uploading rather than after, when a bad value would only show
  # up as a 500 from an edge replica somewhere.
  jq -e '.ALLOWED_EMAILS | length > 0' "$CONFIG_FILE" >/dev/null \
    || { echo "ALLOWED_EMAILS is empty; everyone would be locked out." >&2; exit 1; }
  jq -e '.PRIVATE_KEY | startswith("-----BEGIN")' "$CONFIG_FILE" >/dev/null \
    || { echo "PRIVATE_KEY does not look like a PEM." >&2; exit 1; }

  encoded=$(base64 < "$CONFIG_FILE" | tr -d '\n')

  if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region us-east-1 >/dev/null 2>&1; then
    aws secretsmanager put-secret-value \
      --secret-id "$SECRET_NAME" --region us-east-1 \
      --secret-string "$(jq -nc --arg c "$encoded" '{config: $c}')" >/dev/null
    echo "updated $SECRET_NAME"
  else
    echo "secret $SECRET_NAME does not exist. Run terraform apply first." >&2
    exit 1
  fi

  echo
  # Deleted unconditionally. `rm -i` reads EOF as "no" when stdin is not a
  # terminal, so a piped or scripted run would leave the client secret and the
  # RSA private key on disk while printing that it had cleaned up.
  #
  # Nothing is lost: the edge function reads its config from Secrets Manager,
  # so no local copy is needed. Set KEEP_LOCAL_CONFIG=1 to override.
  if [[ -n "${KEEP_LOCAL_CONFIG:-}" ]]; then
    echo "Uploaded. KEEP_LOCAL_CONFIG is set, so $CONFIG_FILE is being kept."
    echo "It contains the client secret and the signing key. It is gitignored,"
    echo "but delete it when you are done."
  else
    rm -f "$CONFIG_FILE"
    echo "Uploaded, and removed the local plaintext copy."
  fi
  echo
  echo "Next: republish the edge function so replicas pick up the new config."
  echo "  (config is cached per replica; a new version forces a fresh fetch)"
  exit 0
fi

# --- build -----------------------------------------------------------------

if [[ -f "$CONFIG_FILE" ]]; then
  read -rp "$CONFIG_FILE already exists. Overwrite? [y/N] " ans
  [[ "$ans" == "y" ]] || exit 1
fi

# Defaults come from terraform so the redirect URI cannot drift from the
# CloudFront behaviour that serves it.
TF_REDIRECT="$(tf_output oidc_redirect_uri)"
if [[ -n "$TF_REDIRECT" ]]; then
  DEFAULT_DOMAIN="${TF_REDIRECT#https://}"
  DEFAULT_CALLBACK="/${DEFAULT_DOMAIN#*/}"
  DEFAULT_DOMAIN="${DEFAULT_DOMAIN%%/*}"
  echo "terraform says the redirect URI is: $TF_REDIRECT"
  echo
else
  DEFAULT_DOMAIN=""
  DEFAULT_CALLBACK="/_callback"
  echo "note: could not read terraform outputs; enter the values manually."
  echo
fi

read -rp "Short domain${DEFAULT_DOMAIN:+ [$DEFAULT_DOMAIN]}: " DOMAIN
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
[[ -n "$DOMAIN" ]] || { echo "domain is required" >&2; exit 1; }

read -rp "OIDC client id: " CLIENT_ID
read -rsp "OIDC client secret (not echoed): " CLIENT_SECRET; echo
read -rp "Allowed emails, comma separated: " EMAILS
[[ -n "$EMAILS" ]] || { echo "at least one address is required" >&2; exit 1; }

read -rp "Callback path [$DEFAULT_CALLBACK]: " CALLBACK
CALLBACK="${CALLBACK:-$DEFAULT_CALLBACK}"
read -rp "Session duration in seconds [43200]: " DURATION
DURATION="${DURATION:-43200}"

echo
echo "Generating a fresh RSA keypair for session cookies..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null
openssl rsa -in "$tmp/private.pem" -pubout -out "$tmp/public.pem" 2>/dev/null

jq -n \
  --arg client_id "$CLIENT_ID" \
  --arg client_secret "$CLIENT_SECRET" \
  --arg base "https://$DOMAIN" \
  --arg callback "$CALLBACK" \
  --arg private "$(cat "$tmp/private.pem")" \
  --arg public "$(cat "$tmp/public.pem")" \
  --argjson duration "$DURATION" \
  --arg emails "$EMAILS" \
  '{
    client_id: $client_id,
    client_secret: $client_secret,
    scope: "openid email",
    response_type: "code",
    grant_type: "authorization_code",
    CALLBACK_BASE_URL: $base,
    CALLBACK_PATH: $callback,
    DISCOVERY_DOCUMENT_URL: "https://accounts.google.com/.well-known/openid-configuration",
    ISSUER: "https://accounts.google.com",
    AUTHORIZATION_ENDPOINT: "https://accounts.google.com/o/oauth2/v2/auth",
    TOKEN_ENDPOINT: "https://oauth2.googleapis.com/token",
    JWKS_URI: "https://www.googleapis.com/oauth2/v3/certs",
    PRIVATE_KEY: $private,
    PUBLIC_KEY: $public,
    SESSION_DURATION: $duration,
    ALLOWED_EMAILS: ($emails | split(",") | map(gsub("^\\s+|\\s+$"; ""))),
    JSON_PATH_PREFIXES: ["/api/"]
  }' > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"

echo
echo "Wrote $CONFIG_FILE (gitignored, mode 600)"
jq '.client_secret = "<redacted>" | .PRIVATE_KEY = "<redacted>" | .PUBLIC_KEY = "<redacted>"' "$CONFIG_FILE"
echo
echo "Register this redirect URI at the IdP:"
echo "  https://${DOMAIN}${CALLBACK}"
echo
echo "Then: ./scripts/edge-auth-config.sh push"
