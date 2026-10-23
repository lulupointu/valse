#!/usr/bin/env python3
"""Helpers for scripts/test.sh and scripts/uitest.sh: failing tests from a swift-testing xUnit report, the quarantine
list (app/Tests/quarantine.txt) and its validation.

  testlib.py unit-failures <xunit.xml>   one line per failed test: <Suite.test>\t<--filter regex>\t<quarantine reason|->\t<first issue|->
  testlib.py passed <xunit.xml>          exit 0 when the report has ≥ 1 test and no failure
  testlib.py quarantined <ui|unit> <id>  prints the reason and exits 0 when <id> is quarantined, else exits 1
  testlib.py check-quarantine            validates the file (format, date, reason, the test / script exists)
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUARANTINE = os.path.join(ROOT, "app", "Tests", "quarantine.txt")
LINE = re.compile(r"^(unit|ui)\s+(\S+)\s+(\d{4}-\d{2}-\d{2})\s+(.+)$")


def quarantine():
    entries, errors = [], []
    if not os.path.exists(QUARANTINE):
        return entries, errors
    for n, raw in enumerate(open(QUARANTINE, encoding="utf-8"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE.match(line)
        if not m:
            errors.append(f"quarantine.txt:{n}: expected '<unit|ui> <id> <YYYY-MM-DD> <reason>', got: {line}")
            continue
        entries.append({"kind": m.group(1), "id": m.group(2), "date": m.group(3), "reason": m.group(4), "line": n})
    return entries, errors


def unit_matches(entry_id, suite_qualified, func):
    """entry 'AudioUITests.autoBeatsWritesClipBeats' (or just 'autoBeatsWritesClipBeats') vs a failed test."""
    full = f"{suite_qualified}.{func}"
    return entry_id == func or full == entry_id or full.endswith("." + entry_id)


def reason_for(kind, suite_qualified, func):
    entries, _ = quarantine()
    for e in entries:
        if e["kind"] != kind:
            continue
        if kind == "ui" and e["id"] == func:
            return f"{e['reason']} (quarantined {e['date']})"
        if kind == "unit" and unit_matches(e["id"], suite_qualified, func):
            return f"{e['reason']} (quarantined {e['date']})"
    return None


def cases(path):
    root = ET.parse(path).getroot()
    return list(root.iter("testcase"))


def unit_failures(path):
    for tc in cases(path):
        if tc.find("failure") is None and tc.find("error") is None:
            continue
        cls = tc.get("classname", "")            # MontageUITests.AudioUITests (module.Suite[.Nested])
        name = tc.get("name", "")                # autoBeatsWritesClipBeats() / paramFails(x:)
        func = name.split("(")[0]
        suite = cls.split(".", 1)[1] if "." in cls else cls
        flt = re.escape(cls) + "/" + re.escape(name)
        reason = reason_for("unit", suite, func) or "-"
        # 4th column: the first issue's message on one line (a flake's evidence; the run's logs are overwritten later)
        el = tc.find("failure") if tc.find("failure") is not None else tc.find("error")
        msg = re.sub(r"\s+", " ", (el.get("message") or el.text or "").strip())[:400] or "-"
        print(f"{suite}.{func}\t{flt}\t{reason}\t{msg}")


def passed(path):
    cs = cases(path)
    ran = [c for c in cs if c.find("skipped") is None]
    return bool(ran) and all(c.find("failure") is None and c.find("error") is None for c in cs)


def check_quarantine():
    entries, errors = quarantine()
    tests = os.path.join(ROOT, "app", "Tests")
    sources = {}
    for d, _, files in os.walk(tests):
        for f in files:
            if f.endswith(".swift"):
                sources[os.path.join(d, f)] = open(os.path.join(d, f), encoding="utf-8").read()
    for e in entries:
        if e["kind"] == "ui":
            if not os.path.exists(os.path.join(tests, "UIScripts", e["id"] + ".json")):
                errors.append(f"quarantine.txt:{e['line']}: no UI script app/Tests/UIScripts/{e['id']}.json")
            continue
        parts = e["id"].split(".")
        func, suite = parts[-1], (parts[-2] if len(parts) > 1 else None)
        fn = re.compile(r"\bfunc\s+" + re.escape(func) + r"\s*\(")
        hits = [p for p, s in sources.items() if fn.search(s) and (suite is None or re.search(r"\b(struct|class|extension|enum)\s+" + re.escape(suite) + r"\b", s))]
        if not hits:
            errors.append(f"quarantine.txt:{e['line']}: no test func {func}() in a {suite or 'test'} suite under app/Tests")
    for err in errors:
        print(err, file=sys.stderr)
    return not errors


def main(argv):
    if len(argv) < 2:
        print(__doc__); return 2
    cmd = argv[1]
    if cmd == "unit-failures":
        unit_failures(argv[2]); return 0
    if cmd == "passed":
        try:
            return 0 if passed(argv[2]) else 1
        except (OSError, ET.ParseError):
            return 1
    if cmd == "quarantined":
        r = reason_for(argv[2], "", argv[3]) if argv[2] == "ui" else reason_for("unit", argv[3].rsplit(".", 1)[0], argv[3].rsplit(".", 1)[-1])
        if r:
            print(r); return 0
        return 1
    if cmd == "check-quarantine":
        ok = check_quarantine()
        if ok:
            n = len(quarantine()[0])
            print(f"quarantine: {n} entries OK")
        return 0 if ok else 1
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
