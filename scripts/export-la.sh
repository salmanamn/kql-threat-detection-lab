#!/usr/bin/env bash
# Export Log Analytics tables from the Project 1 platform workspace.
#   schemas/<Table>.kql       (committed)   .create-merge table with LA column names + types
#   data/import/<Table>.csv   (gitignored)  rows, subscription id masked
# Usage: scripts/export-la.sh [days]        default 30
# Env:   LA_RG (rg-slz-platform), LA_WORKSPACE (log-slz-platform)
set -euo pipefail
cd "$(dirname "$0")/.."

DAYS="${1:-30}"
RG="${LA_RG:-rg-slz-platform}"
WS="${LA_WORKSPACE:-log-slz-platform}"
TABLES=(AzureActivity StorageBlobLogs NTANetAnalytics)
MASK="00000000-0000-0000-0000-000000000000"

SUB="$(az account show --query id -o tsv)"
WSID="$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query customerId -o tsv)"
mkdir -p schemas data/import
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "workspace $WS ($WSID), last ${DAYS}d"
for T in "${TABLES[@]}"; do
  jq -n --arg q "$T | where TimeGenerated > ago(${DAYS}d) | sort by TimeGenerated asc" '{query: $q}' > "$tmp/body.json"

  if ! az rest --method post --resource https://api.loganalytics.io \
       --url "https://api.loganalytics.io/v1/workspaces/$WSID/query" \
       --body @"$tmp/body.json" -o json > "$tmp/$T.json" 2> "$tmp/$T.err"; then
    printf '%-18s skipped: %s\n' "$T" "$(head -n1 "$tmp/$T.err" | cut -c1-160)"
    continue
  fi

  # Schema: exact LA column names/types, bracket-quoted (handles reserved words)
  jq -r --arg t "$T" '.tables[0].columns
    | map("[\"" + .name + "\"]:" + .type)
    | ".create-merge table " + $t + " (" + join(", ") + ")"' "$tmp/$T.json" > "schemas/$T.kql"

  # Rows: CSV in column order; dynamic -> JSON text; subscription id masked (case-insensitive)
  jq -r --arg sub "$SUB" --arg mask "$MASK" '.tables[0].rows[]
    | map(if type == "string" then gsub($sub; $mask; "i")
          elif type == "object" or type == "array" then (tojson | gsub($sub; $mask; "i"))
          else . end)
    | @csv' "$tmp/$T.json" > "data/import/$T.csv"

  printf '%-18s %6s rows  %3s columns\n' "$T" \
    "$(jq '.tables[0].rows | length' "$tmp/$T.json")" \
    "$(jq '.tables[0].columns | length' "$tmp/$T.json")"
done