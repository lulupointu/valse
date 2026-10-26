#!/usr/bin/env python3
"""Writes the Sparkle appcast.xml of one Montage release to stdout (called by scripts/release.sh, SE-015).

One item: the full Montage.zip plus a binary delta per previous release found in --deltas (files named
Montage<build>-<from build>.delta). Every archive is signed with Sparkle's sign_update (EdDSA private key from the
login keychain). The appcast is an asset of the release itself, so releases/latest/download/appcast.xml always
describes the newest release.
"""
import argparse
import email.utils
import os
import re
import subprocess
import sys
from xml.sax.saxutils import escape, quoteattr


def sign(tool, path, key_file=None):
    out = subprocess.run([tool, path] + (["--ed-key-file", key_file] if key_file else []), check=True, capture_output=True, text=True).stdout
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', out)
    if not m:
        sys.exit(f"sign_update gave no signature for {path}: {out!r}")
    return m.group(1), m.group(2)


def main():
    ap = argparse.ArgumentParser()
    for a in ("--version", "--build", "--repo", "--tag", "--sign-update", "--zip", "--deltas"):
        ap.add_argument(a, required=True)
    ap.add_argument("--min-system", default="13.0")
    ap.add_argument("--base-url", help="download URL prefix instead of the GitHub release (scripts/updater_e2e.sh)")
    ap.add_argument("--ed-key-file", help="private key file instead of the login keychain (scripts/updater_e2e.sh)")
    a = ap.parse_args()
    base = a.base_url or f"https://github.com/{a.repo}/releases/download/{a.tag}/"
    sig, length = sign(a.sign_update, a.zip, a.ed_key_file)
    deltas = []
    for name in sorted(os.listdir(a.deltas)):
        m = re.fullmatch(rf"Montage{re.escape(a.build)}-(\d+)\.delta", name)
        if not m:
            continue
        dsig, dlen = sign(a.sign_update, os.path.join(a.deltas, name), a.ed_key_file)
        deltas.append(
            f'        <enclosure url={quoteattr(base + name)} sparkle:deltaFrom="{m.group(1)}" '
            f'length="{dlen}" type="application/octet-stream" sparkle:edSignature="{dsig}"/>'
        )
    delta_xml = ("\n      <sparkle:deltas>\n" + "\n".join(deltas) + "\n      </sparkle:deltas>") if deltas else ""
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Montage</title>
    <item>
      <title>{escape(a.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.min_system)}</sparkle:minimumSystemVersion>
      <link>{escape(f"https://github.com/{a.repo}/releases/tag/{a.tag}")}</link>
      <enclosure url={quoteattr(base + "Montage.zip")} length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>{delta_xml}
    </item>
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
