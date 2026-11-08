#!/usr/bin/env bash
# Run a KQL query or management command against the local Kusto emulator.
# Usage:
#   scripts/kql.sh '<query or .command>'
#   scripts/kql.sh -f path/to/file.kql
# Env: KUSTO_URL (default http://localhost:8080), KUSTO_DB (default SecLab), KQL_RAW=1 -> raw JSON
set -euo pipefail

KUSTO_URL="${KUSTO_URL:-http://localhost:8080}"
KUSTO_DB="${KUSTO_DB:-SecLab}"

if [[ "${1:-}" == "-f" ]]; then
  [[ -f "${2:-}" ]] || { echo "file not found: ${2:-}" >&2; exit 2; }
  csl="$(cat "$2")"
else
  csl="${1:-}"
fi
[[ -n "$csl" ]] || { echo "usage: $0 '<kql>' | -f file.kql" >&2; exit 2; }

# Management commands start with '.' (ignoring blank lines and // comments)
first="$(printf '%s\n' "$csl" | sed -e 's/^[[:space:]]*//' | { grep -v -e '^//' -e '^$' || true; } | head -n1)"
if [[ "$first" == .* ]]; then endpoint="mgmt"; else endpoint="query"; fi

body="$(jq -n --arg db "$KUSTO_DB" --arg csl "$csl" '{db: $db, csl: $csl}')"
resp="$(mktemp)"
trap 'rm -f "$resp"' EXIT

code="$(curl -sS -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" "$KUSTO_URL/v1/rest/$endpoint")"

if [[ "$code" != "200" ]]; then
  echo "HTTP $code ($endpoint)" >&2
  jq -r '.error["@message"] // .error.message // .' "$resp" >&2 2>/dev/null || cat "$resp" >&2
  exit 1
fi

if [[ "${KQL_RAW:-0}" == "1" ]]; then cat "$resp"; exit 0; fi

# Primary result as TSV with a header row; dynamic values printed as compact JSON
jq -r '.Tables[0]
  | ((.Columns | map(.ColumnName)),
     (.Rows[] | map(if type == "object" or type == "array" then tojson else . end)))
  | @tsv' "$resp"