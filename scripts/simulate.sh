#!/usr/bin/env bash
# Generate real detection signal against the EPHEMERAL Project 1 stack (state account: read attempt only).
#   scripts/simulate.sh run <stack-rg>   during a lab session (after ci-deploy.sh apply)
#   scripts/simulate.sh purge            after ci-deploy.sh destroy (vault is soft-deleted)
# Every action is logged in UTC to data/sim/<timestamp>-<mode>.log with the detection it should trigger.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
STATE_ACCOUNT="${STATE_ACCOUNT:-stslztfstatet8trox}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
LOCATION="${LOCATION:-uaenorth}"
mkdir -p data/sim
LOG="data/sim/$(date -u +%Y%m%dT%H%M%SZ)-${MODE:-none}.log"
STATE_FILE="data/sim/last-stack.env"

log() { printf '%s  %-8s %s\n' "$(date -u +%FT%TZ)" "$1" "$2" | tee -a "$LOG"; }

# act <detection> <description> <command...>        command must succeed
act() { local d="$1" m="$2"; shift 2; log "$d" "$m"; "$@" > /dev/null; }

# act_refused <detection> <description> <command...> command is expected to be refused
act_refused() {
  local d="$1" m="$2"; shift 2
  log "$d" "$m (expect refusal)"
  if "$@" > /dev/null 2> "$LOG.err"; then
    log "WARN" "  ^ was NOT refused"
  else
    log "ok" "  refused: $(grep -m1 -iE 'error|not permitted|forbidden|purge' "$LOG.err" | cut -c1-150)"
  fi
}

run() {
  local rg="${1:?usage: $0 run <stack-rg>}"
  local rgid me nsg st law kv kvid assignment diag
  rgid="$(az group show -n "$rg" --query id -o tsv)"
  me="$(az ad signed-in-user show --query id -o tsv)"
  nsg="$(az network nsg list -g "$rg" --query '[0].name' -o tsv)"
  st="$(az storage account list -g "$rg" --query '[0].name' -o tsv)"
  law="$(az monitor log-analytics workspace list -g "$rg" --query '[0].name' -o tsv)"
  kv="$(az keyvault list -g "$rg" --query '[0].name' -o tsv)"
  kvid="$(az keyvault show -n "$kv" --query id -o tsv)"
  assignment="$(az policy assignment list --scope "$rgid" --query '[0].id' -o tsv)"
  diag="$(az monitor diagnostic-settings list --resource "$kvid" --query '[0].name' -o tsv)"
  for v in nsg st law kv assignment diag; do
    [[ -n "${!v}" ]] || { echo "could not discover $v in $rg" >&2; exit 1; }
  done
    # First free inbound priority from 100 up (the stack NSG already uses 4000 for deny-internet-inbound)
  local taken prio=100
  taken="$(az network nsg rule list -g "$rg" --nsg-name "$nsg" --query "[?direction=='Inbound'].priority" -o tsv)"
  while grep -qx "$prio" <<< "$taken"; do prio=$((prio + 1)); done
  printf 'RG=%s\nKV=%s\n' "$rg" "$kv" > "$STATE_FILE"
  log "info" "stack $rg: nsg=$nsg storage=$st workspace=$law vault=$kv diag=$diag"

  act SLZ-001 "role assignment create (Reader, self, stack RG)" \
    az role assignment create --assignee-object-id "$me" --assignee-principal-type User --role Reader --scope "$rgid"
  act SLZ-003 "list storage keys on $st" \
    az storage account keys list -g "$rg" -n "$st"
  act SLZ-003 "get workspace shared keys on $law" \
    az monitor log-analytics workspace get-shared-keys -g "$rg" -n "$law"
  act SLZ-004 "NSG rule: allow inbound tcp/22 from Internet on $nsg" \
    az network nsg rule create -g "$rg" --nsg-name "$nsg" -n sim-allow-ssh-internet --priority "$prio" \
      --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet --destination-port-ranges 22
  act SLZ-002 "policy exemption on the stack assignment" \
    az policy exemption create -n sim-exemption --scope "$rgid" --policy-assignment "$assignment" \
      --exemption-category Waiver --display-name "SLZ detection simulation"
  act SLZ-007 "delete diagnostic setting $diag on $kv" \
    az monitor diagnostic-settings delete --resource "$kvid" -n "$diag"
  # The CLI fetches the account key first (listKeys -> also SLZ-003), then the data request is refused.
  act_refused SLZ-006 "Shared Key read of Terraform state ($STATE_ACCOUNT)" \
    az storage blob list --account-name "$STATE_ACCOUNT" -c "$STATE_CONTAINER" --auth-mode key --num-results 1

  log "info" "waiting 60 s before cleanup"
  sleep 60
  act SLZ-004 "cleanup: delete NSG rule" \
    az network nsg rule delete -g "$rg" --nsg-name "$nsg" -n sim-allow-ssh-internet
  act SLZ-002 "cleanup: delete policy exemption" \
    az policy exemption delete -n sim-exemption --scope "$rgid"
  act SLZ-001 "cleanup: role assignment delete" \
    az role assignment delete --assignee "$me" --role Reader --scope "$rgid"
  log "done" "log: $LOG"
}

purge() {
  [[ -f "$STATE_FILE" ]] || { echo "no $STATE_FILE: run '$0 run <rg>' first" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  az keyvault show-deleted -n "$KV" -o none 2>/dev/null \
    || { echo "vault $KV is not soft-deleted yet (run after ci-deploy.sh destroy)" >&2; exit 1; }
  act_refused SLZ-005 "purge soft-deleted vault $KV (purge protection on)" \
    az keyvault purge -n "$KV" -l "$LOCATION"
  log "done" "log: $LOG"
}

cleanup() {
  local rg="${1:?usage: $0 cleanup <stack-rg>}" rgid me nsg
  rgid="$(az group show -n "$rg" --query id -o tsv)"
  me="$(az ad signed-in-user show --query id -o tsv)"
  nsg="$(az network nsg list -g "$rg" --query '[0].name' -o tsv)"
  log "info" "best-effort cleanup in $rg"
  az network nsg rule delete -g "$rg" --nsg-name "$nsg" -n sim-allow-ssh-internet > /dev/null 2>&1 || true
  az policy exemption delete -n sim-exemption --scope "$rgid" > /dev/null 2>&1 || true
  az role assignment delete --assignee "$me" --role Reader --scope "$rgid" > /dev/null 2>&1 || true
  log "done" "cleanup finished; remaining sim role assignments: $(az role assignment list --assignee "$me" --role Reader --scope "$rgid" --query 'length(@)' -o tsv)"
}

case "$MODE" in
  run)     shift; run "$@" ;;
  purge)   purge ;;
  cleanup) shift; cleanup "$@" ;;
  *)       echo "usage: $0 run <stack-rg> | purge | cleanup <stack-rg>" >&2; exit 2 ;;
esac