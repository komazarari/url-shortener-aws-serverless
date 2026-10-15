#!/usr/bin/env bash
#
# diagnose-edge-auth.sh - find out why CloudFront won't run the edge function
#
# CloudFront returns
#   503 "The Lambda function associated with the CloudFront distribution is
#        invalid or doesn't have the required permissions"
# when replication fails. The function never runs, so there are no logs to read
# and the message does not say which precondition was violated.
#
# This checks every documented Lambda@Edge restriction against the live
# configuration and reports which one is broken.
#
# Usage:
#   ./scripts/diagnose-edge-auth.sh
#   FUNCTION=my-edge-fn DIST_ID=E123 ./scripts/diagnose-edge-auth.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$HERE/../terraform"

# Duplicated verbatim in edge-auth-config.sh. These are standalone operator
# scripts meant to be runnable and copyable on their own, so a shared library
# would buy less than it costs in sourcing failures. Keep the two identical.
tf_output() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true; }

FUNCTION="${FUNCTION:-$(tf_output edge_auth_function_name)}"
FUNCTION="${FUNCTION:-url-shortener-edge-auth}"
DIST_ID="${DIST_ID:-$(tf_output cloudfront_distribution_id)}"

command -v aws >/dev/null || { echo "aws CLI required" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq required" >&2; exit 1; }

fails=0
ok()   { printf '  \033[32mOK  \033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mNG  \033[0m %s\n' "$1"; fails=$((fails + 1)); }
info() { printf '       %s\n' "$1"; }

echo "function: $FUNCTION (us-east-1)"
echo

cfg=$(aws lambda get-function-configuration \
        --function-name "$FUNCTION" --region us-east-1 2>/dev/null)
if [[ -z "$cfg" ]]; then
  echo "could not read the function in us-east-1. Wrong name, or not deployed?" >&2
  exit 1
fi

echo "== function configuration =="

runtime=$(jq -r '.Runtime' <<<"$cfg")
info "runtime: $runtime"
case "$runtime" in
  nodejs18.x|nodejs20.x|nodejs22.x|python3.1[0-9]|python3.9)
    ok "runtime is one Lambda@Edge is documented to accept" ;;
  *)
    bad "runtime '$runtime' may not be supported at the edge"
    info "Lambda@Edge trails plain Lambda by a release or two. Try nodejs20.x." ;;
esac

arch=$(jq -r '.Architectures[0]' <<<"$cfg")
[[ "$arch" == "x86_64" ]] && ok "architecture x86_64" \
  || bad "architecture is $arch; Lambda@Edge does not support arm64"

mem=$(jq -r '.MemorySize' <<<"$cfg")
[[ "$mem" -le 128 ]] && ok "memory ${mem} MB (viewer limit 128)" \
  || bad "memory ${mem} MB exceeds the 128 MB viewer-event limit"

timeout=$(jq -r '.Timeout' <<<"$cfg")
[[ "$timeout" -le 5 ]] && ok "timeout ${timeout}s (viewer limit 5)" \
  || bad "timeout ${timeout}s exceeds the 5s viewer-event limit"

envcount=$(jq -r '.Environment.Variables // {} | length' <<<"$cfg")
[[ "$envcount" -eq 0 ]] && ok "no environment variables" \
  || bad "$envcount environment variables set; Lambda@Edge forbids them"

layers=$(jq -r '.Layers // [] | length' <<<"$cfg")
[[ "$layers" -eq 0 ]] && ok "no layers" || bad "$layers layers attached; not supported"

vpc=$(jq -r '.VpcConfig.VpcId // ""' <<<"$cfg")
[[ -z "$vpc" ]] && ok "no VPC config" || bad "VPC config present; not supported"

ephemeral=$(jq -r '.EphemeralStorage.Size // 512' <<<"$cfg")
[[ "$ephemeral" -le 512 ]] && ok "ephemeral storage ${ephemeral} MB" \
  || bad "ephemeral storage ${ephemeral} MB exceeds 512 MB"

pkgsize=$(jq -r '.CodeSize' <<<"$cfg")
if [[ "$pkgsize" -le 1048576 ]]; then
  ok "package $(( pkgsize / 1024 )) KB (viewer limit 1 MB)"
else
  bad "package $(( pkgsize / 1024 )) KB exceeds the 1 MB viewer limit"
fi

rtmgmt=$(aws lambda get-runtime-management-config \
           --function-name "$FUNCTION" --region us-east-1 2>/dev/null \
           | jq -r '.UpdateRuntimeOn // "Auto"')
[[ "$rtmgmt" == "Auto" ]] && ok "runtime management is Auto" \
  || bad "runtime management is '$rtmgmt'; only Auto is supported"

echo
echo "== execution role trust policy =="

role_arn=$(jq -r '.Role' <<<"$cfg")
role_name="${role_arn##*/}"
info "role: $role_name"

trust=$(aws iam get-role --role-name "$role_name" \
          --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)
if [[ -z "$trust" ]]; then
  bad "could not read the role"
else
  principals=$(jq -r '[.Statement[].Principal.Service] | flatten | .[]' <<<"$trust" 2>/dev/null)
  for needed in lambda.amazonaws.com edgelambda.amazonaws.com; do
    grep -qx "$needed" <<<"$principals" && ok "trusts $needed" \
      || bad "trust policy is missing $needed  <-- classic cause of this 503"
  done
fi

echo
echo "== published versions =="
versions=$(aws lambda list-versions-by-function --function-name "$FUNCTION" \
             --region us-east-1 --query 'Versions[?Version!=`$LATEST`].Version' \
             --output text 2>/dev/null)
if [[ -n "$versions" ]]; then
  ok "published versions: $versions"
else
  bad "no published version; CloudFront cannot reference \$LATEST"
fi

if [[ -n "$DIST_ID" ]]; then
  echo
  echo "== CloudFront associations =="
  assoc=$(aws cloudfront get-distribution-config --id "$DIST_ID" 2>/dev/null \
            | jq -r '[.DistributionConfig.DefaultCacheBehavior,
                      (.DistributionConfig.CacheBehaviors.Items // [])[]]
                     | .[] | select(.LambdaFunctionAssociations.Quantity > 0)
                     | .LambdaFunctionAssociations.Items[].LambdaFunctionARN' 2>/dev/null)
  if [[ -z "$assoc" ]]; then
    info "no Lambda@Edge associations found"
  else
    while read -r arn; do
      [[ -z "$arn" ]] && continue
      ver="${arn##*:}"
      if [[ "$ver" =~ ^[0-9]+$ ]]; then
        if grep -qw "$ver" <<<"$versions"; then
          ok "association points at version $ver, which exists"
        else
          bad "association points at version $ver, which no longer exists"
        fi
      else
        bad "association uses '$ver' rather than a numbered version"
      fi
    done <<<"$assoc"
  fi

  status=$(aws cloudfront get-distribution --id "$DIST_ID" \
             --query 'Distribution.Status' --output text 2>/dev/null)
  info "distribution status: $status"
  [[ "$status" == "Deployed" ]] || info "still deploying; wait before retesting"
fi

echo
echo "== replicas =="
# Replicas appear as us-east-1.<name> in regions that have served traffic.
found=0
for region in ap-northeast-1 us-east-1 us-west-2 eu-west-1; do
  if aws lambda get-function --function-name "us-east-1.$FUNCTION" \
       --region "$region" >/dev/null 2>&1; then
    ok "replica present in $region"
    found=1
  fi
done
[[ "$found" -eq 1 ]] || info "no replicas yet (normal if nothing has hit the edge, or if replication failed)"

echo
echo "=================================================="
if [[ "$fails" -eq 0 ]]; then
  echo " every documented restriction checks out."
  echo " If the 503 persists, replication may still be in progress -- it can"
  echo " take several minutes after the distribution reports Deployed."
else
  echo " $fails problem(s) found above."
fi
exit "$fails"
