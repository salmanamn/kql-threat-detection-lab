# Decisions

## D1 — Separate repo, read-only use of Project 1
Project 1 (`secure-landing-zone`) stays frozen. This repo only *reads* from `log-slz-platform`
(AzureActivity, StorageBlobLogs, NTANetAnalytics). Real signal is generated through Project 1's
CI apply/destroy (caller = `id-slz-apply`) plus scripted actions in M4.

## D2 — Kusto emulator, pinned by digest, data rebuildable
`kustainer-linux:stable`, pinned by digest in `docker-compose.yml`. The emulator volume is a cache,
not a source of truth: Microsoft does not guarantee extent/metadata compatibility between emulator
versions, and retention/merge policies are not honoured. `scripts/kusto-init.sh` creates or
re-attaches `SecLab`. Committed fixtures (and gitignored exports) are the source of truth; tables are
re-loaded from them. Observed on re-create: <re-attached | already attached>.

## D3 — curl + jq client, no Kusto.CLI
`scripts/kql.sh` posts to `/v1/rest/query` or `/v1/rest/mgmt` (auto-detected by a leading `.`).
No .NET dependency, identical locally and in CI.

## D4 — Local tables mirror Log Analytics schemas exactly
Table and column names/types match the workspace (taken from `getschema` in M2), so a detection's
KQL text is byte-identical locally, in Log Analytics, and in Sentinel. Only the time window is
parameterised.

## D5 — Export via Log Analytics query REST, CSV by column position
`scripts/export-la.sh` calls `POST https://api.loganalytics.io/v1/workspaces/<id>/query` via `az rest`
(typed columns; `az monitor log-analytics query` returns untyped strings). One call per table gives
both `schemas/<Table>.kql` (committed) and `data/import/<Table>.csv` (gitignored; subscription id
masked, case-insensitive). CSV is ingested by column position, so no ingestion mappings.
Hidden columns (`_ResourceId`, `_SubscriptionId`, `_BilledSize`, ...) are not returned by a plain
query and are therefore not in the local schema; detections must not depend on them.
`NTANetAnalytics` is schema-only until a VM exists (Project 1 D19).

## D6 — Detection format: Sentinel analytics-rule YAML
One `detections/<SLZ-id>-<slug>.yaml` per rule (id GUID, severity, frequency/period, tactics,
techniques incl. sub-techniques, entity mappings, query). Terraform consumes it via `yamldecode()`
in M5. Queries carry **no** `TimeGenerated` filter; the rule's `queryPeriod` applies it in Sentinel.
Allowlists live in the `KnownPrincipals()` function (`functions/*.kql`): a stored function locally,
a Log Analytics saved function in M5, so the query text is identical everywhere (D4).
Only CI identities (`ci`) and Azure first-party services (`platform`) are allowlisted, never humans.

## D7 — Test discipline
`scripts/test-detections.py` (uv inline deps) loads fixtures into `SecLabTest` (dropped/recreated
per case, so it never touches the real data in `SecLab`). Each detection must have a fixture with
at least one positive and one negative case; fixture columns are validated against
`schemas/*.kql`, so typos fail loudly. Status filters accept both `Success` and `Succeeded`.
`--real` runs the same detections against exported workspace data.
Finding: azurerm refreshes call `listKeys` / `sharedKeys` even on Entra-only resources, so SLZ-003
allowlists CI and fires on hand applies of `platform/` and `bootstrap/` (true positive, by design).


## D8 — Allowlist roles and per-detection scope
`KnownPrincipals()` roles: `ci` (id-slz-apply/plan), `platform` (NetworkTrafficAnalyticsService,
Azure Traffic Manager and DNS, both seen in real AzureActivity), `operator` (the human running the
by-hand roots). `operator` is honoured only by SLZ-006 (state access is routine for hand applies);
RBAC, keys, policy and logging detections always fire on humans. CI is deliberately *not* exempt
from SLZ-004 (Internet-open NSG), from policy exemptions (SLZ-002), from purge attempts (SLZ-005), or
from logging deletes on persistent targets (SLZ-007): CI only legitimately destroys the ephemeral stack.
Status semantics: `Start` carries request bodies, `Accept` = async 202, final = `Success`/`Succeeded`.
Lead (to verify in M4): NetworkTrafficAnalyticsService calls ListServiceSas on the flow-log account,
which has Shared Key off, so Traffic Analytics may be unable to read flow logs (Project 1 D19).

## D9 — CI
`detections.yml` runs the repo's `docker-compose.yml` (single digest pin), lint + all fixture tests,
then a "tests must be able to fail" step with a corrupted allowlist (same idea as Project 1's
weak-must-fail). Branch protection requires the `detections` check (strict).
