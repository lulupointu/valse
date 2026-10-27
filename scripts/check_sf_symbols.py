#!/usr/bin/env python3
"""Check every SF Symbol name used in app/Sources against the macOS deployment floor (default 13.0).

On macOS 13 a symbol introduced after SF Symbols 4 renders as NOTHING (no error, no log).
Source of truth (on the build host):
  CoreGlyphs.bundle/.../name_availability.plist  symbol -> release ("2022" = macOS 13.0, "2022.2" = 13.3, "2023" = 14 ...)
  CoreGlyphs.bundle/.../name_aliases.strings      old spelling -> current spelling. An old spelling keeps resolving on new
                                                  systems, so a RENAMED glyph is written with its old name (same glyph).

Rules (exit 1 on any violation):
  * every Swift string literal under app/Sources that is a known symbol name (or alias) must exist on the floor, unless
    every occurrence is wrapped as `compat("name")` (ValseCore SFSymbolCompat) AND the helper's fallback exists there;
  * names the code composes at runtime (DYNAMIC below) are checked too;
  * every literal passed to systemName: / systemImage: / systemSymbolName: must be a known name at all.
NOT_SYMBOLS lists literals that collide with a symbol name but are ids / words, never drawn as symbols.

Usage: scripts/check_sf_symbols.py [--floor 13.0] [--list]
ValseUITests/SFSymbolAvailabilityTests runs this script and also checks the registries' symbols at runtime.
"""
import json, os, plistlib, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources"
COMPAT = os.path.join(ROOT, "app/Sources/ValseCore/Localization/SFSymbolCompat.swift")
# Names composed at runtime: base literal -> suffixes appended to it.
#   Transitions.directions -> "\(sym).square", "\(sym).square.fill"; LibraryBrowser nav entries -> s + ".fill".
DYNAMIC = {**{f"arrow.{d}": (".square", ".square.fill") for d in ("left", "right", "up", "down")},
           "star": (".fill",), "clock": (".fill",)}
# Literals equal to a too-new symbol name that are NOT drawn as symbols, per file (ids, tags, keys, `log show --last 2h`).
# Keep this per file: the same word can be a symbol elsewhere ("fireworks" is both a sticker id and an effect symbol).
NOT_SYMBOLS = {
    "*": {"left", "right"},   # dictionary keys / edge names everywhere; never drawn as a symbol
    "ValseEngine/Media/SupportPackage.swift": {"2h"},
    "ValseUI/Text/TextInspector.swift": {"bubble"},
    "ValseEffects/Builtin/Stickers.swift": {"cat", "dog", "fireworks", "rainbow", "microphone", "ring"},
    "ValseEffects/Builtin/Effects.swift": {"fireworks"},
    "ValseEffects/Builtin/TextStyles.swift": {"rainbow"},
    "ValseEffects/Builtin/FX+Particles.swift": {"fireworks", "rainbow"},
    "ValseEffects/Builtin/FX+Light.swift": {"rainbow"},
    "ValseEffects/Builtin/FX+Art.swift": {"rainbow"},
    "ValseUI/AssetPanel/Library/StockLibrary.swift": {"rainbow", "ring"},
    "ValseAI/Vision/MediaIndex.swift": {"document", "dog", "cat"},
    "ValseUI/Home/Keymap.swift": {"left", "right"},
    "ValseUI/Recording/RecorderView.swift": {"microphone"},
}
LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')
# IconButton("name", …) (ValseUI Support/Controls) takes its symbol unlabelled: OB-08, "magnet" is no SF Symbol.
API = re.compile(r'(systemName\s*:|systemImage\s*:|systemSymbolName\s*:|IconButton\()\s*"([^"\\]+)"')
PAIR = re.compile(r'^\s*"([a-z0-9.]+)"\s*:\s*"([a-z0-9.]+)"\s*,')


def vt(s):
    return tuple(int(x) for x in s.split("."))


def load():
    with open(f"{RES}/name_availability.plist", "rb") as f:
        av = plistlib.load(f)
    aliases = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", f"{RES}/name_aliases.strings"]))
    return av["symbols"], av["year_to_release"], aliases


def first_macos(name, symbols, releases, aliases):
    """Earliest macOS version where `name` draws a glyph, or None when the name is unknown."""
    y = symbols.get(name)
    if y is None and name in aliases:
        y = symbols.get(aliases[name])
    return releases[y]["macOS"] if y else None


def compat_table():
    out = {}
    with open(COMPAT, encoding="utf-8") as f:
        for line in f:
            m = PAIR.match(line)
            if m:
                out[m.group(1)] = m.group(2)
    return out


def scan():
    """literal -> list of (where, wrapped_in_compat); API literal occurrences."""
    used, api = {}, []
    for d, _, files in os.walk(os.path.join(ROOT, "app/Sources")):
        for fn in sorted(files):
            p = os.path.join(d, fn)
            if not fn.endswith(".swift") or p == COMPAT:
                continue
            rel = os.path.relpath(p, ROOT)
            ignore = NOT_SYMBOLS["*"] | NOT_SYMBOLS.get(os.path.relpath(p, os.path.join(ROOT, "app/Sources")), set())
            with open(p, encoding="utf-8") as f:
                for i, line in enumerate(f, 1):
                    for m in LIT.finditer(line):
                        s = m.group(1)
                        wrapped = line[:m.start()].endswith("compat(")
                        if "\\(" in s or (s in ignore and not wrapped):
                            continue
                        used.setdefault(s, []).append((f"{rel}:{i}", wrapped))
                    for m in API.finditer(line):
                        api.append((f"{rel}:{i}", m.group(2)))
    return used, api


def main():
    floor = sys.argv[sys.argv.index("--floor") + 1] if "--floor" in sys.argv else "13.0"
    symbols, releases, aliases = load()
    known = set(symbols) | set(aliases)
    compat = compat_table()
    old_spelling = {}
    for old, new in aliases.items():
        old_spelling.setdefault(new, []).append(old)

    def ok(n):
        mos = first_macos(n, symbols, releases, aliases)
        return mos is not None and vt(mos) <= vt(floor)

    used, api = scan()
    bad, checked = [], set()
    for s, occ in sorted(used.items()):
        if s not in known:
            continue
        for n in [s] + [s + suf for suf in DYNAMIC.get(s, ()) if s + suf in known]:
            checked.add(n)
            if ok(n):
                continue
            mos = first_macos(n, symbols, releases, aliases)
            hint = [o for o in old_spelling.get(n, []) if ok(o)]
            hint = f" (same glyph, old spelling: {', '.join(hint)})" if hint else ""
            for where, wrapped in occ:
                if n != s or not wrapped:
                    bad.append((where, n, f"needs macOS {mos}; wrap it in SFSymbolCompat.compat(...) or pick an older glyph{hint}"))
                elif n not in compat:
                    bad.append((where, n, f"needs macOS {mos} and has no SFSymbolCompat.fallbacks entry"))
    for where, n in api:
        if n not in known:
            bad.append((where, n, "unknown symbol name (renders nothing)"))
    for n, fb in sorted(compat.items()):
        if not ok(fb):
            bad.append((os.path.relpath(COMPAT, ROOT), fb, f"fallback for '{n}' is not available on macOS {floor}"))
    if "--list" in sys.argv:
        for n in sorted(checked):
            print(f"{n}\t{first_macos(n, symbols, releases, aliases)}")
    for where, n, why in bad:
        print(f"{where}: '{n}' {why}")
    print(f"{len(checked)} SF Symbol names checked, {len(bad)} violations (floor macOS {floor})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
