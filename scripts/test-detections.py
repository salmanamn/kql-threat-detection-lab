#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6"]
# ///
"""Detection tests on the local Kusto emulator.

  scripts/test-detections.py            run tests/fixtures/<detection>.yaml in database SecLabTest
  scripts/test-detections.py --real     run every detection against exported data in SecLab
  scripts/test-detections.py -k SLZ-001 only detections whose file name contains SLZ-001
Env: KUSTO_URL (default http://localhost:8080)
"""
import argparse
import csv
import datetime as dt
import io
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
URL = os.environ.get("KUSTO_URL", "http://localhost:8080")
TEST_DB, REAL_DB = "SecLabTest", "SecLab"
COL_RE = re.compile(r'\["([^"]+)"\]:(\w+)')


class KustoError(Exception):
    pass


def kusto(db, csl):
    endpoint = "mgmt" if csl.lstrip().startswith(".") else "query"
    req = urllib.request.Request(
        f"{URL}/v1/rest/{endpoint}",
        data=json.dumps({"db": db, "csl": csl}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            table = json.load(r)["Tables"][0]
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            err = json.loads(raw)["error"]
            msg = err.get("@message") or err.get("message") or raw
        except (ValueError, KeyError, TypeError):
            msg = raw
        raise KustoError(f"HTTP {e.code}: {msg}") from None
    return [c["ColumnName"] for c in table["Columns"]], table["Rows"]


def ensure_db(db):
    env = dict(os.environ, KUSTO_DB=db)
    subprocess.run([str(ROOT / "scripts" / "kusto-init.sh")], env=env, check=True, stdout=subprocess.DEVNULL)


def load_schemas():
    out = {}
    for f in sorted((ROOT / "schemas").glob("*.kql")):
        text = f.read_text()
        out[f.stem] = (text, [m.group(1) for m in COL_RE.finditer(text)])
    if not out:
        raise SystemExit("no schemas/*.kql")
    return out


def load_functions(db):
    for f in sorted((ROOT / "functions").glob("*.kql")):
        kusto(db, f".create-or-alter function {f.stem}() {{\n{f.read_text().strip()}\n}}")


SEVERITIES = {"Informational", "Low", "Medium", "High"}
TACTICS = {
    "Reconnaissance", "ResourceDevelopment", "InitialAccess", "Execution", "Persistence",
    "PrivilegeEscalation", "DefenseEvasion", "CredentialAccess", "Discovery", "LateralMovement",
    "Collection", "Exfiltration", "CommandAndControl", "Impact",
}
TECH_RE = re.compile(r"^T\d{4}(\.\d{3})?$")
GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
REQUIRED = ("id", "name", "description", "severity", "queryFrequency", "queryPeriod",
            "tactics", "relevantTechniques", "query")


def load_detections(k):
    out, seen, errors = [], {}, []
    for f in sorted((ROOT / "detections").glob("*.yaml")):
        d = yaml.safe_load(f.read_text())
        missing = [key for key in REQUIRED if key not in d]
        if missing:
            errors.append(f"{f.name}: missing {missing}")
            continue
        rid, prefix = str(d["id"]), f.stem[:7]
        if not GUID_RE.match(rid):
            errors.append(f"{f.name}: id must be a lower-case GUID")
        if rid in seen:
            errors.append(f"{f.name}: duplicate id (also in {seen[rid]})")
        seen[rid] = f.name
        if not str(d["name"]).startswith(prefix):
            errors.append(f"{f.name}: name must start with {prefix}")
        if d["severity"] not in SEVERITIES:
            errors.append(f"{f.name}: severity {d['severity']!r} not in {sorted(SEVERITIES)}")
        bad = [t for t in d["tactics"] if t not in TACTICS]
        if bad:
            errors.append(f"{f.name}: unknown tactics {bad}")
        bad = [t for t in d["relevantTechniques"] if not TECH_RE.match(str(t))]
        if bad:
            errors.append(f"{f.name}: bad technique ids {bad}")
        sev_col = (d.get("alertDetailsOverride") or {}).get("alertSeverityColumnName")
        if sev_col and sev_col not in d["query"]:
            errors.append(f"{f.name}: alertSeverityColumnName {sev_col!r} not produced by the query")
        if k and k not in f.stem:
            continue
        out.append((f, d))
    if errors:
        raise SystemExit("detection lint failed:\n  " + "\n  ".join(errors))
    return out

def cell(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, dt.datetime):
        if v.tzinfo is None:
            v = v.replace(tzinfo=dt.timezone.utc)
        return v.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def to_csv(table, columns, rows):
    unknown = sorted({k for r in rows for k in r} - set(columns))
    if unknown:
        raise SystemExit(f"fixture uses columns not in schemas/{table}.kql: {unknown}")
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    for r in rows:
        w.writerow([cell(r.get(c)) for c in columns])
    return buf.getvalue()


def reset_tables(db, schemas):
    for t, (text, _) in schemas.items():
        kusto(db, f".drop table {t} ifexists")
        kusto(db, text)


def run_tests(dets, schemas):
    ensure_db(TEST_DB)
    load_functions(TEST_DB)
    passed = failed = 0
    for f, d in dets:
        print(d["name"])
        fx = ROOT / "tests" / "fixtures" / f.name
        if not fx.exists():
            print(f"  FAIL  missing tests/fixtures/{f.name}")
            failed += 1
            continue
        cases = yaml.safe_load(fx.read_text())["cases"]
        if not any(c["expect"] > 0 for c in cases) or not any(c["expect"] == 0 for c in cases):
            print("  FAIL  needs >=1 positive (expect > 0) and >=1 negative (expect: 0) case")
            failed += 1
        for c in cases:
            reset_tables(TEST_DB, schemas)
            for t, rows in (c.get("rows") or {}).items():
                if t not in schemas:
                    raise SystemExit(f"{fx.name}: unknown table {t}")
                kusto(TEST_DB, f".ingest inline into table {t} <|\n" + to_csv(t, schemas[t][1], rows))
            try:
                cols, res = kusto(TEST_DB, d["query"])
            except KustoError as e:
                print(f"  FAIL  {c['name']}: {e}")
                failed += 1
                continue
            got = len(res)
            ok = got == c["expect"]
            detail = f"expected {c['expect']}, got {got}"
            for col, want in (c.get("expect_values") or {}).items():
                if col not in cols:
                    ok, detail = False, f"{detail}; column {col} missing"
                    continue
                vals = sorted({str(r[cols.index(col)]) for r in res})
                if vals != [str(want)]:
                    ok, detail = False, f"{detail}; {col}={vals}, want {want}"
            print(f"  {'PASS' if ok else 'FAIL'}  {c['name']} ({detail})")
            passed += ok
            failed += not ok
    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


def run_real(dets):
    load_functions(REAL_DB)
    for _, d in dets:
        cols, rows = kusto(REAL_DB, d["query"])
        print(f"{d['name']}: {len(rows)} hit(s)")
        for r in rows:
            print("    " + " | ".join(f"{c}={v}" for c, v in zip(cols, r) if v not in (None, "", [])))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--real", action="store_true", help="run against exported data in SecLab")
    ap.add_argument("-k", default="", help="filter detections by file-name substring")
    a = ap.parse_args()
    dets = load_detections(a.k)
    if not dets:
        raise SystemExit("no detections matched")
    try:
        sys.exit(run_real(dets) if a.real else run_tests(dets, load_schemas()))
    except KustoError as e:
        raise SystemExit(f"kusto: {e}")


if __name__ == "__main__":
    main()