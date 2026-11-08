#!/usr/bin/env bash
# Run KQL against the real workspace (log-slz-platform) and print TSV with a header row.
# Usage: scripts/la-query.sh '<kql>'  |  scripts/la-query.sh -f file.kql
# Env:   LA_RG (rg-slz-platform), LA_WORKSPACE (log-slz-platform)
set -euo pipefail

RG="${LA_RG:-rg-slz-platform}"
WS="${LA_WORKSPACE:-log-slz-platform}"
if [[ "${1:-}" == "-f" ]]; then q="$(cat "$2")"; else q="${1:?usage: $0 '<kql>' | -f file.kql}"; fi

WSID="$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query customerId -o tsv)"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
jq -n --arg q "$q" '{query: $q}' > "$body"

az rest --method post --resource https://api.loganalytics.io \
  --url "https://api.loganalytics.io/v1/workspaces/$WSID/query" --body @"$body" -o json \
  | jq -r '.tables[0]
      | ((.columns | map(.name)),
         (.rows[] | map(if type == "object" or type == "array" then tojson else . end)))
      | @tsv'