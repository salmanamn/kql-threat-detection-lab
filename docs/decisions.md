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
