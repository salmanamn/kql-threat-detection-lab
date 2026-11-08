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