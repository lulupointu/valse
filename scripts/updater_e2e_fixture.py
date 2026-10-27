#!/usr/bin/env python3
"""Pre-rename user data for scripts/updater_e2e.sh: installs the legacy project fixture (a `.montage` package with
"montage.…" content IDs, app/Tests/UIScripts/fixtures/legacy, see LegacyMontageProjectTests) into a sandboxed home as
Montage left it: the package in ~/Movies/Montage, its pasted picture in ~/Library/Application Support/Montage, and the
library index (library.json) filing it in a Home folder by its absolute path.
Usage: updater_e2e_fixture.py <fixture package> <home> <destination package>
"""
import json
import os
import sys
import urllib.parse
import uuid

src, home, dest = sys.argv[1:4]
home = os.path.abspath(home)
TOKEN = "/__HOME__"
encoded = urllib.parse.quote(home)


def resolve(v):
    if isinstance(v, str):
        return v.replace(TOKEN, encoded if v.startswith("file://") else home)
    if isinstance(v, list):
        return [resolve(x) for x in v]
    if isinstance(v, dict):
        return {resolve(k): resolve(x) for k, x in v.items()}
    return v


os.makedirs(dest, exist_ok=True)
for name in ("project.json", "summary.json"):
    with open(os.path.join(src, name)) as f:
        obj = resolve(json.load(f))
    with open(os.path.join(dest, name), "w") as f:
        json.dump(obj, f, sort_keys=True)

support = os.path.join(home, "Library/Application Support/Montage")
os.makedirs(os.path.join(support, "Pasted Media"), exist_ok=True)
with open(os.path.join(support, "Pasted Media/legacy.png"), "wb") as f:
    f.write(b"png")
folder = str(uuid.uuid4()).upper()
index = {"version": 1, "folders": [{"id": folder, "name": "Old work", "createdAt": 800000000.0}],
         "meta": {os.path.abspath(dest): {"folderID": folder, "lastOpened": 800000100.0}}, "external": [], "cache": {}}
with open(os.path.join(support, "library.json"), "w") as f:
    json.dump(index, f, sort_keys=True)
print(dest)
