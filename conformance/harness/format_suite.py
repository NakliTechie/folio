#!/usr/bin/env python3
"""
Tier F — Format & integrity conformance runner.

Reads corpus/manifest.json (cases) + corpus/invariants.json (checks) and asserts every
applicable invariant against each corpus .khata. Engine-agnostic: it opens the file's
books.sqlite directly, no adapter involved. Stdlib only (zipfile, sqlite3, hashlib, json).

Exit 0 = all invariants hold. Exit 1 = one or more failed (details printed).

    python3 harness/format_suite.py
"""

import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # conformance/
CORPUS = ROOT / "corpus"


def load_json(p):
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def open_books(khata_path):
    """Return (manifest_dict, sqlite3.Connection, books_bytes, tmp_path)."""
    z = zipfile.ZipFile(khata_path)
    manifest = json.loads(z.read("manifest.json"))
    books = z.read("books.sqlite")
    tf = tempfile.NamedTemporaryFile(delete=False, suffix=".sqlite")
    tf.write(books)
    tf.close()
    con = sqlite3.connect(tf.name)
    con.row_factory = sqlite3.Row
    return manifest, con, books, tf.name


# ─────────────────────────────────────────────────────── native checks ─────
# Each returns (ok: bool, detail: str).

def native_file_size_min(inv, ctx):
    size = os.path.getsize(ctx["path"])
    return size >= inv["min"], f"size={size} min={inv['min']}"


def native_zip_has(inv, ctx):
    with zipfile.ZipFile(ctx["path"]) as z:
        names = set(z.namelist())
    missing = [e for e in inv["entries"] if e not in names]
    return not missing, f"missing={missing}" if missing else "ok"


def native_pragma_integrity(inv, ctx):
    row = ctx["con"].execute("PRAGMA integrity_check").fetchone()
    return row[0] == "ok", f"integrity_check={row[0]}"


def native_schema_version(inv, ctx):
    exp = inv["expected"]
    man = ctx["manifest"].get("schemaVersion")
    meta = ctx["con"].execute("SELECT v FROM meta WHERE k='schemaVersion'").fetchone()
    meta_v = int(meta["v"]) if meta else None
    ok = man == exp and meta_v == exp
    return ok, f"manifest={man} meta={meta_v} expected={exp}"


def native_format_version(inv, ctx):
    v = ctx["manifest"].get("khataFormatVersion")
    return v == inv["expected"], f"format={v} expected={inv['expected']}"


def native_books_hash(inv, ctx):
    actual = hashlib.sha256(ctx["books"]).hexdigest()
    expected = ctx["manifest"]["integrity"]["booksHash"]
    return actual == expected, f"books sha256 {'match' if actual == expected else actual + ' != ' + expected}"


def native_audit_head(inv, ctx):
    last = ctx["con"].execute("SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1").fetchone()
    expected = ctx["manifest"]["integrity"]["auditHead"]
    return last is not None and last["hash"] == expected, f"head {'match' if last and last['hash'] == expected else 'MISMATCH'}"


def native_company_identity(inv, ctx):
    m = ctx["manifest"]["company"]
    exp = ctx["case"]["identity"]
    ok = m.get("gstin") == exp["gstin"] and m.get("name") == exp["name"] and m.get("state") == exp["state"]
    return ok, f"got=({m.get('gstin')},{m.get('name')},{m.get('state')}) expected=({exp['gstin']},{exp['name']},{exp['state']})"


def native_chain_links(inv, ctx):
    """Structural hash-walk: genesis + every prev_hash links to the prior row's hash.
    (Full sha256 recomputation is Tier C, via the adapter.)"""
    rows = ctx["con"].execute("SELECT id, prev_hash, hash FROM audit_log ORDER BY id").fetchall()
    if not rows:
        return False, "empty audit_log"
    genesis = rows[0]["prev_hash"]
    if genesis not in ("", "0" * 64, None):
        return False, f"genesis prev_hash={genesis!r}"
    prev = None
    for r in rows:
        if prev is not None and r["prev_hash"] != prev:
            return False, f"chain break at row id={r['id']}"
        prev = r["hash"]
    return True, f"{len(rows)} rows link cleanly"


NATIVE = {
    "file-size-min": native_file_size_min,
    "zip-has": native_zip_has,
    "pragma-integrity": native_pragma_integrity,
    "schema-version": native_schema_version,
    "format-version": native_format_version,
    "books-hash": native_books_hash,
    "audit-head": native_audit_head,
    "company-identity": native_company_identity,
    "chain-links": native_chain_links,
}


# ─────────────────────────────────────────────────────────── sql checks ─────

def subst(sql, ctx):
    return sql.replace("{{home_state}}", ctx["case"]["homeState"])


def check_sql_empty(inv, ctx):
    rows = ctx["con"].execute(subst(inv["sql"], ctx)).fetchall()
    return len(rows) == 0, f"{len(rows)} violating rows" + (f" e.g. {tuple(rows[0])}" if rows else "")


def check_sql_scalar_zero(inv, ctx):
    v = ctx["con"].execute(subst(inv["sql"], ctx)).fetchone()[0] or 0
    return v == 0, f"scalar={v} (expected 0)"


def check_sql_scalar_eq(inv, ctx):
    v = ctx["con"].execute(subst(inv["sql"], ctx)).fetchone()[0]
    return v == inv["expected"], f"scalar={v} expected={inv['expected']}"


def check_sql_scalar_min(inv, ctx):
    v = ctx["con"].execute(subst(inv["sql"], ctx)).fetchone()[0] or 0
    return v >= inv["min"], f"scalar={v} min={inv['min']}"


def check_sql_two_scalars_rel(inv, ctx):
    row = ctx["con"].execute(subst(inv["sql"], ctx)).fetchone()
    a, b = row[0] or 0, row[1] or 0
    if a == 0:
        return True, "a=0 (vacuously ok)"
    rel = abs(a - b) / abs(a)
    return rel <= inv["tolRel"], f"a={a} b={b} rel={rel:.4f} tol={inv['tolRel']}"


CHECKS = {
    "sql-empty": check_sql_empty,
    "sql-scalar-zero": check_sql_scalar_zero,
    "sql-scalar-eq": check_sql_scalar_eq,
    "sql-scalar-min": check_sql_scalar_min,
    "sql-two-scalars-rel": check_sql_two_scalars_rel,
}


def applies(inv, case_id):
    a = inv["appliesTo"]
    return "*" in a or case_id in a


def main():
    manifest = load_json(CORPUS / "manifest.json")
    invariants = load_json(CORPUS / "invariants.json")["invariants"]
    cases = manifest["cases"]

    total = passed = 0
    failures = []

    for case in cases:
        path = CORPUS / case["file"]
        m, con, books, tmp = open_books(path)
        ctx = {"case": case, "manifest": m, "con": con, "books": books, "path": str(path)}
        try:
            for inv in invariants:
                if not applies(inv, case["id"]):
                    continue
                total += 1
                try:
                    if inv["kind"] == "native":
                        ok, detail = NATIVE[inv["native"]](inv, ctx)
                    else:
                        ok, detail = CHECKS[inv["kind"]](inv, ctx)
                except Exception as e:  # noqa: BLE001
                    ok, detail = False, f"EXCEPTION {type(e).__name__}: {e}"
                if ok:
                    passed += 1
                else:
                    failures.append((case["id"], inv["id"], inv["desc"], detail))
        finally:
            con.close()
            os.unlink(tmp)

    print(f"Tier F — Format & integrity: {passed}/{total} assertions passed "
          f"({len(invariants)} invariants x applicable files across {len(cases)} cases)")
    if failures:
        print(f"\n{len(failures)} FAILED:")
        for cid, iid, desc, detail in failures:
            print(f"  ✗ [{cid}] {iid}: {desc}\n      {detail}")
        return 1
    print("  ✓ all invariants hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
