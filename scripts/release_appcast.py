#!/usr/bin/env python3
"""Writes the Sparkle appcast.xml of one Valse release to stdout (called by scripts/release.sh, SE-015).

Items:
- The release itself: the full Valse.zip plus a binary delta per previous release found in --deltas (files named
  Valse<build>-<from build>.delta), on the `valse` channel (`<sparkle:channel>valse</sparkle:channel>`). Only Valse
  builds see it: they declare `allowedChannels = ["valse"]` (ValseApp/Updater.swift).
- The bridge item, without a channel, so copies installed before the rename (Montage ≤ 0.3, bundle id
  fr.montage.Montage, which know no channels) see it and nothing else. Its archive (Valse-bridge.zip, kept forever on
  the bridge release) holds the Valse app under the old bundle name `Montage.app`, the only name Sparkle in those
  copies accepts (it matches the installed bundle's file name; the bundle id changed). That Valse build renames
  itself to Valse.app at first launch and from then on follows the channel item.
  `--bridge`: this release IS the bridge: its single item is the bridge item (no channel, --zip is the
  Montage.app-named archive) and no deltas. Otherwise the bridge item is copied from --previous-appcast (the appcast of
  the latest published release, which always carries it).
Every archive is signed with Sparkle's sign_update (EdDSA private key from the login keychain, or --ed-key-file).
The appcast is an asset of the release itself, so releases/latest/download/appcast.xml always describes the newest one.
"""
import argparse
import email.utils
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CHANNEL = "valse"
BRIDGE_ASSET = "Valse-bridge.zip"


def sign(tool, path, key_file=None):
    out = subprocess.run([tool, path] + (["--ed-key-file", key_file] if key_file else []), check=True, capture_output=True, text=True).stdout
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', out)
    if not m:
        sys.exit(f"sign_update gave no signature for {path}: {out!r}")
    return m.group(1), m.group(2)


def bridge_item_xml(appcast_path):
    """The channel-less item whose archive is the bridge zip, re-serialized, or None."""
    ET.register_namespace("sparkle", SPARKLE_NS)
    root = ET.parse(appcast_path).getroot()
    for item in root.iter("item"):
        if item.find(f"{{{SPARKLE_NS}}}channel") is not None:
            continue
        enc = item.find("enclosure")
        if enc is not None and enc.get("url", "").rsplit("/", 1)[-1] == BRIDGE_ASSET:
            ET.indent(item, space="  ", level=2)
            xml = ET.tostring(item, encoding="unicode").strip()
            # ElementTree writes the namespace declaration on the item; the rss root already declares it
            return "    " + xml.replace(f' xmlns:sparkle="{SPARKLE_NS}"', "")
    return None


def main():
    ap = argparse.ArgumentParser()
    for a in ("--version", "--build", "--repo", "--tag", "--sign-update", "--zip"):
        ap.add_argument(a, required=True)
    ap.add_argument("--deltas", help="folder of Valse<build>-<from>.delta files")
    ap.add_argument("--bridge", action="store_true", help="this release is the bridge release (see above)")
    ap.add_argument("--previous-appcast", help="appcast.xml of the latest published release (carries the bridge item)")
    ap.add_argument("--min-system", default="13.0")
    ap.add_argument("--base-url", help="download URL prefix instead of the GitHub release (scripts/updater_e2e.sh)")
    ap.add_argument("--ed-key-file", help="private key file instead of the login keychain (scripts/updater_e2e.sh)")
    a = ap.parse_args()
    base = a.base_url or f"https://github.com/{a.repo}/releases/download/{a.tag}/"
    sig, length = sign(a.sign_update, a.zip, a.ed_key_file)
    zip_name = os.path.basename(a.zip)
    if a.bridge and zip_name != BRIDGE_ASSET:
        sys.exit(f"--bridge: the archive must be named {BRIDGE_ASSET} (got {zip_name})")
    deltas = []
    if a.deltas and not a.bridge:
        for name in sorted(os.listdir(a.deltas)):
            m = re.fullmatch(rf"Valse{re.escape(a.build)}-(\d+)\.delta", name)
            if not m:
                continue
            dsig, dlen = sign(a.sign_update, os.path.join(a.deltas, name), a.ed_key_file)
            deltas.append(
                f'        <enclosure url={quoteattr(base + name)} sparkle:deltaFrom="{m.group(1)}" '
                f'length="{dlen}" type="application/octet-stream" sparkle:edSignature="{dsig}"/>'
            )
    delta_xml = ("\n      <sparkle:deltas>\n" + "\n".join(deltas) + "\n      </sparkle:deltas>") if deltas else ""
    channel_xml = "" if a.bridge else f"\n      <sparkle:channel>{CHANNEL}</sparkle:channel>"
    items = [f"""    <item>
      <title>{escape(a.version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(a.min_system)}</sparkle:minimumSystemVersion>{channel_xml}
      <link>{escape(f"https://github.com/{a.repo}/releases/tag/{a.tag}")}</link>
      <enclosure url={quoteattr(base + zip_name)} length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>{delta_xml}
    </item>"""]
    if not a.bridge:
        bridge = bridge_item_xml(a.previous_appcast) if a.previous_appcast and os.path.exists(a.previous_appcast) else None
        if bridge is None:
            sys.exit("no bridge item in --previous-appcast: publish the bridge release first (scripts/release.sh <version> "
                     "--bridge), docs/RELEASING.md")
        items.append(bridge)
    body = "\n".join(items)
    print(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>Valse</title>
{body}
  </channel>
</rss>""")


if __name__ == "__main__":
    main()
