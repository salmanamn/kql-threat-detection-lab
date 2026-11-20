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

## D10 — Real-signal simulation and findings (2026-11-08)
`scripts/simulate.sh run <stack-rg>` performs one action per detection against the ephemeral stack
during a CI-deployed lab session and cleans up after itself; `purge` attempts a purge of the
soft-deleted vault after CI destroy; `state` makes a key-signed read of the Terraform state account
(expected to be refused); `cleanup` recovers from a partial run. Evidence:
`docs/evidence/m4-real-run.txt` (UPN and IP last octet masked).

Results: SLZ-001/002/003/004/005/007 fired on real logs. SLZ-007 also caught two historical true
positives (hand deletion of `ala-slz-service-health-incidents` during Project 1 S2-4).

Findings:
- A purge refused by purge protection (HTTP 405 `MethodNotAllowed`) *is* logged:
  `ActivityStatusValue=Failure`, scope = subscription.
- **Logging gap:** storage writes no `StorageBlobLogs` record for requests rejected with
  `KeyBasedAuthenticationNotPermitted` (verified by request id). SLZ-006's non-Entra branch therefore
  only fires if Shared Key is re-enabled (successful AccountKey requests are logged). The observable
  signal for a Shared Key attack on state is the control-plane listKeys on the state account (SLZ-003).
  Follow-up: detect Shared Key / public access being re-enabled (SLZ-008), and raise SLZ-003
  severity when the target is the state account (Sentinel dynamic severity, M5).
- NSG simulation priority must be free: the stack NSG uses 4000 for `deny-internet-inbound`.
- D19 lead (Traffic Analytics ListServiceSas vs Shared Key off) cannot be checked from the laptop;
  stays open until a VM exists.

## D11 — Closing the D10 gap
SLZ-008 alerts on a succeeded storage write that enables Shared Key, enables anonymous blob access,
or lowers TLS below 1.2 (request body on the Start event, joined to Success). No allowlist: the
weak stack demo (`hardened=false`) through CI is a true positive. Policy-denied writes never succeed
and do not alert. SLZ-003 emits `AlertSeverity` (High for `stslztfstate*` targets) and maps it with
`alertDetailsOverride.alertSeverityColumnName`; fixtures assert it with `expect_values`, and the lint
checks that the override column is produced by the query.

## D12 — Sentinel root
`sentinel/` is a persistent root applied by hand (like Project 1 `platform/`); state in the Project 1
state account, key `kql-sentinel.tfstate`. It onboards Sentinel on `log-slz-platform`, deploys
`functions/KnownPrincipals.kql` as a saved function (alias `KnownPrincipals`), and creates one
scheduled rule per `detections/*.yaml` via `yamldecode()`: GUID `id` as rule name, durations mapped
to ISO 8601 (unknown values fail the plan), parent techniques in `techniques`, sub-techniques in
`sub_techniques`, `AlertPerResult` event grouping (needed for SLZ-003 per-row severity), incident
grouping on all entities within 5 h. The workspace ID is built from names: a workspace data source
reads shared keys on refresh and would trigger SLZ-003 on every operator apply. A 90 s `time_sleep`
lets the new function index before Sentinel validates the queries. Sentinel free trial (10 GB/day,
31 days) covers the lab; as the tenant's first Sentinel workspace it is auto-onboarded to the
Defender portal, where incidents appear. Teardown: destroy `sentinel/` before Project 1 `platform/`.

## D13 — Sentinel validation (M5c)
Re-ran the D10 simulation with the rules live. Sentinel raised alerts for SLZ-001/002/003/004/005/007;
SLZ-003 produced Medium and High alerts in one run (per-row `AlertSeverity` via
`alertDetailsOverride`), and entity mapping yielded account, ip and azure-resource entities.
SLZ-006 stays silent by design (D10 logging gap); SLZ-008 had nothing to see (all writes hardened).
Incidents: grouped per rule on all entities within 5 h; the Defender portal correlation engine may
merge further, so alert counts are the acceptance check. Evidence: `docs/evidence/m5-sentinel-incidents.txt`.
`scripts/la-query.sh` runs KQL against the real workspace via the query REST API.

## D14 — Detections for the ticket-triage stack (SLZ-009, SLZ-010)
Project 3 (ticket-triage-agent) deploys through the same two CI identities, so `KnownPrincipals()`
needed no change. Its stack is Entra-only, which makes two control-plane actions worth an alert.
**SLZ-009**: keys or connection strings of Service Bus, Cosmos DB, Event Grid, Azure OpenAI and
Communication Services, and Function App host/function keys, listed or regenerated by anyone but CI
(azurerm refreshes list them with the plan identity; the code deploy reads the host keys with the
apply identity). With local auth off those keys are useless, so the listing is Medium; Function App
keys are High because the function key still authenticates the ingest API. The operator fetches that
key for every manual test (`az functionapp keys list`): an expected true positive, like the SLZ-001
hits on bootstrap applies. Kept apart from SLZ-003 so the storage/state rule and its severity logic
stay as they are; a storage listing fires SLZ-003 only (fixture).
First run on real logs (M9): Event Grid's first-party service principal (`Microsoft.EventGrid`,
object id `fe96f09d-…`, owned by Microsoft's tenant) lists the Function App host keys when it
creates or validates a subscription to an Azure Function endpoint, and lists an account SAS while
validating a storage dead-letter destination (SLZ-003). Added to `KnownPrincipals()` as `platform`;
a fixture case in SLZ-009 and SLZ-003 each keeps it allowlisted.
**SLZ-010**: federated identity credential written to or deleted from a user-assigned identity. No
allowlist: only the hand-applied bootstrap root creates them, and a CI identity adding one would be
a pipeline giving itself (or another repository) a way back in. High on `id-slz-*`, Medium elsewhere.
Role assignments to or by identities stay with SLZ-001. Not covered: an identity being attached to
another resource (`userAssignedIdentities/assign/action`; not verified to appear as an Activity Log
event of its own) and the federated subject in the alert (expected in the request body of the Start
event; left out to keep the rule on the Success event alone).

## D15 — AKS's first-party service principal allowlisted (arabic-voice-assistant, M8)
Project 4 (arabic-voice-assistant) deploys an AKS cluster through the same CI identities. Its first
real session (2026-11-20) raised SLZ-001: `AzureContainerService` (object id `24a1e91c-…`, owned by
Microsoft's tenant `f8cdef31-…`) writes a role assignment in the node resource group while the
cluster is created and deletes its role assignments there while it is deleted — AKS managing its own
identities (the five role assignments the stack asks for were all written by `id-slz-apply`). Real
logs of both M8 evenings: 6 such hits (2 writes, 4 deletes). Benign true positives on every cluster
create and delete, so it joins `KnownPrincipals()` as `platform`, with a write and a delete fixture
case in SLZ-001 that keep it allowlisted. The two SLZ-001 hits left in the same window
(`p4-m8-real-run.txt`) are the operator's hand-applied Project 1 bootstrap change for this repo's CI
identities (2026-11-19 15:43): expected true positives, as D14 describes for bootstrap applies.
The same session raised SLZ-010 for the gateway's federated credential (`id-voice-azure-gateway`,
written by `id-slz-apply`): no allowlist by design (D14), so it stays an expected Medium on every
apply and destroy of that stack — close as Benign Positive. D14's "only the hand-applied bootstrap
root creates them" no longer holds: workload-identity stacks create one per apply.
