#!/usr/bin/env bash
# (Re)create tables from schemas/*.kql and ingest data/import/<Table>.csv into SecLab.
# Usage: scripts/load-local.sh [Table ...]   default: every schemas/*.kql
set -euo pipefail
cd "$(dirname "$0")/.."
KQL=./scripts/kql.sh

if [[ $# -gt 0 ]]; then
  tables=("$@")
else
  tables=()
  for f in schemas/*.kql; do tables+=("$(basename "$f" .kql)"); done
fi

for T in "${tables[@]}"; do
  [[ -f "schemas/$T.kql" ]] || { echo "$T: no schemas/$T.kql" >&2; exit 1; }
  $KQL ".drop table $T ifexists" > /dev/null
  $KQL -f "schemas/$T.kql" > /dev/null
  if [[ -s "data/import/$T.csv" ]]; then
    $KQL ".ingest into table $T (@\"/import/$T.csv\") with (format=\"csv\")" > /dev/null
  fi
  printf '%-18s %6s rows\n' "$T" "$($KQL "$T | count" | tail -n1)"
done