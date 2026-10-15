#!/usr/bin/env bash
#
# verify-plan.sh - show what a terraform apply would actually change
#
# Reading a plan by eye is unreliable: a CloudFront distribution has enough
# attributes that a real change hides easily, and a large-looking diff is often
# nothing. This lists the attributes whose values actually differ, and refuses
# to pass if anything would be created or destroyed unexpectedly.
#
# Usage:
#   cd terraform && ../scripts/verify-plan.sh
#
set -euo pipefail

PLAN_FILE="${PLAN_FILE:-tfplan.verify}"

# The plan file carries every variable value, sensitive ones included. Remove it
# however this script exits.
trap 'rm -f "$PLAN_FILE"' EXIT

echo "== planning =="
terraform plan -out="$PLAN_FILE" >/dev/null

# Decoded once. Held in a variable rather than a temp file so the plan -- which
# includes every variable value, sensitive ones included -- never touches disk
# in readable form.
plan_json=$(terraform show -json "$PLAN_FILE")

echo
echo "== actions =="
jq -r <<<"$plan_json" '
  [ .resource_changes[]
    | select((.change.actions // []) != ["no-op"])
    | (.change.actions | join("+"))
  ] | group_by(.) | map({action: .[0], count: length})
    | if length == 0 then "  (no changes)" else .[] | "  \(.action)\t\(.count)" end
'

echo
echo "== being imported =="
jq -r <<<"$plan_json" '
  [ .resource_changes[] | select(.change.importing != null) | .address ]
  | if length == 0 then "  (none)" else .[] | "  " + . end
'

echo
echo "== attributes that actually differ =="
jq -r <<<"$plan_json" '
  .resource_changes[]
  | select((.change.actions // []) | index("update"))
  | .address as $addr
  | (.change.before // {}) as $b
  | (.change.after  // {}) as $a
  | (($b | keys) + ($a | keys) | unique)[]
  | . as $k
  | select(($b[$k] // null) != ($a[$k] // null))
  | "\($addr)\t\($k)"
' | sort -u | awk -F'\t' '{printf "  %-55s %s\n", $1, $2}' | sed 's/^/  /'

echo
echo "== unexpected creates or destroys =="
danger=$(jq -r <<<"$plan_json" '
  [ .resource_changes[]
    | select(((.change.actions // []) | index("delete")) or ((.change.actions // []) | index("create")))
    | select(.change.importing == null)
    | "\(.address) [\(.change.actions | join(","))]"
  ] | .[]
')
if [[ -n "$danger" ]]; then
  echo "  WARNING - these would be created or destroyed:"
  echo "$danger" | sed 's/^/    /'
  echo
  echo "  Review before applying. During an import this always means the"
  echo "  configuration and reality disagree."
  exit 1
else
  echo "  OK: no creates or destroys (imports and updates only)"
fi
