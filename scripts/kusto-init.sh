#!/usr/bin/env bash
# Idempotent: ensure database $KUSTO_DB (default SecLab) exists in the emulator.
# First run -> create (persisted under data/kusto). After container re-create -> re-attach.
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${KUSTO_DB:-SecLab}"
admin() { KUSTO_DB=NetDefaultDB ./scripts/kql.sh "$@"; }

echo "waiting for emulator..."
for i in $(seq 1 60); do
  if admin '.show cluster' >/dev/null 2>&1; then break; fi
  [[ $i -eq 60 ]] && { echo "emulator not ready after 120 s" >&2; exit 1; }
  sleep 2
done

if admin '.show databases | project DatabaseName' | grep -qx "$DB"; then
  echo "database $DB: already attached"
elif [[ -d "data/kusto/dbs/$DB/md" ]]; then
  admin ".attach database $DB from @\"/kustodata/dbs/$DB/md\"" >/dev/null
  echo "database $DB: re-attached"
else
  admin ".create database $DB persist (@\"/kustodata/dbs/$DB/md\", @\"/kustodata/dbs/$DB/data\")" >/dev/null
  echo "database $DB: created"
fi