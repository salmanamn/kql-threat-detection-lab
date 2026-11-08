# KQL Threat Detection Lab

Detections for the Azure landing zone built in
[secure-landing-zone](https://github.com/salmanamn/secure-landing-zone), developed and tested
locally on the Kusto emulator, mapped to MITRE ATT&CK, then deployed as Microsoft Sentinel rules.

## Local lab
    docker compose up -d
    ./scripts/kusto-init.sh
    ./scripts/kql.sh '.show tables'
    docker compose down

Status: M1 (local emulator) done.