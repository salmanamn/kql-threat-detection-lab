# KQL Threat Detection Lab

Detections for the Azure landing zone built in
[secure-landing-zone](https://github.com/salmanamn/secure-landing-zone), developed and tested
locally on the Kusto emulator against real exported logs, mapped to MITRE ATT&CK, and shipped as
Microsoft Sentinel analytics rules.

| ID | Detection | Table | ATT&CK | Severity |
|---|---|---|---|---|
| SLZ-001 | Role assignment changed outside CI | AzureActivity | T1098.003 | Medium |
| SLZ-002 | Policy assignment/definition removed, or exemption created | AzureActivity | T1562 | High |
| SLZ-003 | Storage/workspace keys or SAS listed outside CI | AzureActivity | T1552 | Medium |
| SLZ-004 | NSG rule opens inbound from the Internet | AzureActivity | T1562.007 | High |
| SLZ-005 | Key Vault deleted outside CI, or purge attempted | AzureActivity | T1485 | High |
| SLZ-006 | Terraform state: unexpected principal or non-Entra auth | StorageBlobLogs | T1530, T1552.001 | High |
| SLZ-007 | Logging or alerting removed | AzureActivity | T1562.008 | High |

## Local lab
    docker compose up -d
    ./scripts/kusto-init.sh
    ./scripts/export-la.sh && ./scripts/load-local.sh     # real data from log-slz-platform
    ./scripts/test-detections.py                          # fixtures (SecLabTest)
    ./scripts/test-detections.py --real                   # real data (SecLab)
    docker compose down

Design decisions: [docs/decisions.md](docs/decisions.md).
Status: M3 (detections + CI) done. Next: M4 real signal in Azure, M5 Sentinel.