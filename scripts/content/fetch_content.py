#!/usr/bin/env python3
"""Fetch, verify, transcode and analyse Valse's bundled music + sound-effect library (AU-001 / AU-002 / AU-025).

Development-time only: the app never touches the network. Sources are curated in scripts/content/music_sources.json
and scripts/content/sfx_sources.json (CC0 / public domain only). For every item this script
  1. checks the license statement on the source page (FreePD archived page, FMA track license overlay, Kenney /
     OpenGameArt pack page + the pack's License.txt, Wikimedia Commons API metadata),
  2. downloads the original (retries, Wayback-friendly) and verifies its pinned SHA-256 (`--pin` records new ones),
  3. trims / loudness-normalises and encodes AAC .m4a (afconvert, 48 kHz) into <cache>/out/{music,sfx}/<id>.m4a,
  4. runs `Valse --analyze-content` (duration, BPM, beats, key, peaks, similarity features) and writes the
     committed manifest app/Sources/ValseEngine/Resources/ContentLibrary/content_manifest.json.
scripts/build_app.sh copies <cache>/out into Valse.app/Contents/Resources/Content.

Cache: $VALSE_CONTENT_CACHE or ~/Library/Caches/ValseDev/content (shared by all worktrees, never committed).
Usage: scripts/fetch_music_pack.sh [--pin] [--only music|sfx] [--no-analyze] [--budget-mb 150] [--force-encode]
"""
import argparse, concurrent.futures, datetime, hashlib, html, json, os, re, shutil, subprocess, sys, time
import urllib.parse, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_DIR = os.path.join(ROOT, "scripts", "content")
MANIFEST_OUT = os.path.join(ROOT, "app", "Sources", "ValseEngine", "Resources", "ContentLibrary", "content_manifest.json")
UA = "ValseContentFetch/1.0 (development build script; dev@valse.local)"
CC0_URL = "https://creativecommons.org/publicdomain/zero/1.0/"
LICENSES = {
    "CC0-1.0": ("CC0 1.0 Universal (Public Domain Dedication)", CC0_URL),
    "LicenseRef-PublicDomain": ("Public domain", "https://commons.wikimedia.org/wiki/Commons:Licensing#Public_domain"),
}
MUSIC_LUFS = -14.0      # social-media loudness, gain only (no compression), true peak ≤ −1 dBTP
SFX_PEAK_DB = -1.0
TODAY = datetime.date.today().isoformat()


def log(*a):
    print(*a, flush=True)


def cache_dir():
    dev = os.path.expanduser("~/Library/Caches/ValseDev")
    legacy = os.path.expanduser("~/Library/Caches/MontageDev")   # caches fetched before the Montage → Valse rename
    if not os.path.isdir(dev) and os.path.isdir(legacy):
        dev = legacy
    p = os.environ.get("VALSE_CONTENT_CACHE") or os.path.join(dev, "content")
    return os.path.abspath(p)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def http_get(url, binary=True, tries=6):
    """GET with retries/backoff (the Wayback Machine refuses bursts). Returns (bytes, final_url)."""
    last = None
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA if "wikimedia" in url else "Mozilla/5.0 " + UA})
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.read(), r.geturl()
        except urllib.error.HTTPError as e:
            last = e
            if e.code in (403, 404, 410):
                break
        except Exception as e:  # noqa: BLE001 — network flakiness
            last = e
        time.sleep(3 * (k + 1))
    raise RuntimeError(f"download failed: {url}: {last}")


class Evidence:
    """License pages, kept in <cache>/evidence (one file per URL, first line = fetch date). A page fetched less than
    `max_age` days ago is reused (the Wayback Machine throttles bursts); `--refresh-evidence` refetches everything."""

    def __init__(self, cache, max_age=90):
        self.dir = os.path.join(cache, "evidence")
        os.makedirs(self.dir, exist_ok=True)
        self.mem = {}
        self.max_age = max_age
        import threading
        self.lock = threading.Lock()

    def text(self, url):
        with self.lock:   # one fetch per URL even with parallel workers
            if url in self.mem:
                return self.mem[url][0]
            path = os.path.join(self.dir, hashlib.sha1(url.encode()).hexdigest()[:16] + ".html")
            if os.path.exists(path) and self.max_age > 0:
                head, _, body = open(path).read().partition("\n")
                m = re.search(r"fetched (\d{4}-\d{2}-\d{2})", head)
                if m and (datetime.date.today() - datetime.date.fromisoformat(m.group(1))).days <= self.max_age:
                    self.mem[url] = (body, m.group(1))
                    return body
            data, _ = http_get(url, tries=8)
            if data[:2] == b"\x1f\x8b":
                import gzip
                data = gzip.decompress(data)
            t = data.decode("utf-8", "replace")
            with open(path, "w") as f:
                f.write(f"<!-- {url} fetched {TODAY} -->\n" + t)
            self.mem[url] = (t, TODAY)
            return t

    def date(self, url):
        """ISO date the page was fetched (= the license verification date)."""
        self.text(url)
        return self.mem[url][1]


def require(cond, msg):
    if not cond:
        raise RuntimeError("LICENSE CHECK FAILED: " + msg)


# ---------------------------------------------------------------- license checks (return (license_id, evidence_url))

def check_freepd(ev, it):
    home = strip_html(ev.text(it["licenseCheck"]))
    require(re.search(r"licensed\s+CC0\s+1\.0\s+Universal", home), f"FreePD home page has no CC0 statement ({it['licenseCheck']})")
    page = ev.text(it["page"].replace("/web/2024/", "/web/2024id_/"))
    path = urllib.parse.unquote(urllib.parse.urlparse(it["originalUrl"]).path)
    require(path in html.unescape(page), f"{it['id']}: not listed on {it['page']}")
    return "CC0-1.0", it["licenseCheck"]


def check_fma(ev, it):
    t = ev.text(it["licenseCheck"])
    require("creativecommons.org/publicdomain/zero/1.0" in t, f"{it['id']}: FMA license overlay is not CC0 ({it['licenseCheck']})")
    lic = set(re.findall(r"creativecommons\.org/(?:licenses|publicdomain)/[a-z-]+/[0-9.]+", t))
    require(lic == {"creativecommons.org/publicdomain/zero/1.0"}, f"{it['id']}: unexpected licenses {lic}")
    return "CC0-1.0", it["licenseCheck"]


def check_pack_page(ev, pack):
    t = ev.text(pack["page"])
    if pack["source"] == "kenney":
        require(re.search(r"\bCC0\b", t), f"Kenney page {pack['page']} has no CC0 statement")
    else:  # opengameart: the license field must offer CC0
        m = re.search(r"field-name-field-art-licenses(.*?)</div>\s*</div>", t, re.S)
        block = m.group(1) if m else t
        require("publicdomain/zero/1.0" in block, f"OpenGameArt page {pack['page']} is not CC0")
    return "CC0-1.0", pack["page"]


def commons_info(title):
    q = urllib.parse.urlencode({"action": "query", "format": "json", "titles": title, "prop": "imageinfo",
                                "iiprop": "url|sha1|size|extmetadata"})
    data, _ = http_get("https://commons.wikimedia.org/w/api.php?" + q, binary=False)
    pages = json.loads(data)["query"]["pages"]
    p = next(iter(pages.values()))
    require("imageinfo" in p, f"Commons file missing: {title}")
    return p["imageinfo"][0]


def check_commons(info, title):
    m = info.get("extmetadata", {})
    short = m.get("LicenseShortName", {}).get("value", "")
    attr = m.get("AttributionRequired", {}).get("value", "true")
    require(short in ("CC0", "Public domain"), f"{title}: Commons license is {short!r}")
    require(attr == "false", f"{title}: Commons says attribution is required")
    return ("CC0-1.0" if short == "CC0" else "LicenseRef-PublicDomain"), "https://commons.wikimedia.org/wiki/" + title.replace(" ", "_")


def strip_html(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s or ""))).strip()


# ---------------------------------------------------------------- audio

def run(cmd, **kw):
    for k in range(6):   # the machine may be saturated by parallel builds: retry fork failures
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, **kw)
            break
        except OSError as e:
            if e.errno not in (11, 12, 35) or k == 5:
                raise
            time.sleep(2 * (k + 1))
    if r.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {r.stderr[-800:]}")
    return r


def measure(path, filters=None):
    """(integrated LUFS, true peak dBTP) via ffmpeg ebur128."""
    af = (filters + "," if filters else "") + "ebur128=peak=true"
    r = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", af, "-f", "null", "-"])
    tail = r.stderr[r.stderr.rfind("Summary:"):]
    i = re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", tail)
    p = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    f = lambda m: float(m.group(1)) if m and m.group(1) != "-inf" else -70.0
    return f(i), f(p)


def channels(path):
    r = run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels", "-of", "csv=p=0", path])
    return int((r.stdout.strip() or "2").split(",")[0])


def encode(src, dst, kind, trim=None):
    """Original → normalised 48 kHz float WAV → AAC .m4a (Apple encoder, best quality)."""
    work = dst + ".work.wav"
    pre = []
    if kind == "sfx":
        if trim:
            pre.append(f"atrim=start={trim[0]}:duration={trim[1]},asetpts=N/SR/TB")
        # drop leading / trailing silence so the sound starts on the drop point
        pre.append("silenceremove=start_periods=1:start_threshold=-55dB:start_silence=0.005")
        pre.append("areverse,silenceremove=start_periods=1:start_threshold=-60dB:start_silence=0.05,areverse")
        if trim:
            pre.append(f"afade=t=out:st={max(0.0, trim[1] - 0.6)}:d=0.6")
    chain = ",".join(pre)
    lufs, tp = measure(src, chain or None)
    if kind == "music":
        gain = min(MUSIC_LUFS - lufs, -1.0 - tp)
        gain = max(-12.0, min(8.0, gain))
    else:
        gain = min(SFX_PEAK_DB - tp, -12.0 - lufs)   # peak-normalise, but never louder than −12 LUFS integrated
        gain = max(-20.0, min(24.0, gain))
    af = (chain + "," if chain else "") + f"volume={gain:.2f}dB,aresample=48000"
    ch = 2 if kind == "music" else min(2, channels(src))
    run(["ffmpeg", "-hide_banner", "-v", "error", "-y", "-i", src, "-vn", "-af", af, "-ac", str(ch), "-c:a", "pcm_f32le", work])
    rate = (112000 if ch == 2 else 80000) if kind == "music" else (128000 if ch == 2 else 80000)
    tmp = dst + ".tmp.m4a"
    run(["afconvert", "-f", "m4af", "-d", "aac", "-b", str(rate), "-s", "1", "-q", "127", work, tmp])
    os.replace(tmp, dst)
    os.remove(work)
    return gain


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pin", action="store_true", help="record new/changed original checksums + retrieval dates in the source lists")
    ap.add_argument("--only", choices=["music", "sfx"])
    ap.add_argument("--no-analyze", action="store_true", help="skip the Swift analysis (staging manifest only)")
    ap.add_argument("--force-encode", action="store_true")
    ap.add_argument("--refresh-evidence", action="store_true", help="refetch every license page (default: reuse pages < 90 days old)")
    ap.add_argument("--budget-mb", type=float, default=150)
    ap.add_argument("--jobs", type=int, default=2)
    ap.add_argument("--debug-analyzer", action="store_true", help="use a debug build for the analysis (slower)")
    a = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe", "afconvert", "swift"):
        require(shutil.which(tool), f"{tool} not found")
    cache = cache_dir()
    dl = os.path.join(cache, "downloads"); out = os.path.join(cache, "out")
    for d in (dl, os.path.join(out, "music"), os.path.join(out, "sfx")):
        os.makedirs(d, exist_ok=True)
    for sub in ("music", "sfx"):   # leftovers of an interrupted run
        for f in os.listdir(os.path.join(out, sub)):
            if f.endswith((".work.wav", ".tmp.m4a")):
                os.remove(os.path.join(out, sub, f))
    ev = Evidence(cache, max_age=0 if a.refresh_evidence else 90)
    log(f"cache: {cache}")

    music_src_path = os.path.join(SRC_DIR, "music_sources.json")
    sfx_src_path = os.path.join(SRC_DIR, "sfx_sources.json")
    music_src = json.load(open(music_src_path))
    sfx_src = json.load(open(sfx_src_path))
    pinned_changed = False
    problems = []

    def fetch_original(key, url, pinned, entry):
        """Downloads `url` into the cache (once) and checks the pinned checksum."""
        nonlocal pinned_changed
        ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower() or ".bin"
        path = os.path.join(dl, re.sub(r"[^A-Za-z0-9._-]+", "_", key) + ext)
        if not os.path.exists(path) or (pinned and sha256(path) != pinned):
            data, final = http_get(url)
            if data[:15].lower().startswith(b"<!doctype html") or data[:6].lower() == b"<html>":
                raise RuntimeError(f"{key}: got an HTML page instead of audio from {url}")
            with open(path + ".part", "wb") as f:
                f.write(data)
            os.replace(path + ".part", path)
        h = sha256(path)
        if pinned and h != pinned:
            raise RuntimeError(f"{key}: checksum mismatch {h} != pinned {pinned}")
        if not pinned:
            if not a.pin:
                raise RuntimeError(f"{key}: no pinned sha256 (run with --pin after reviewing the source)")
            entry["sha256"] = h; entry.setdefault("retrieved", TODAY); pinned_changed = True
        entry.setdefault("retrieved", TODAY)
        return path, h

    items = []

    # ---- music
    if a.only in (None, "music"):
        def do_music(it):
            lic, evidence = (check_freepd if it["source"] == "freepd" else check_fma)(ev, it)
            src, h = fetch_original(it["id"], it["url"], it.get("sha256"), it)
            dst = os.path.join(out, "music", it["id"] + ".m4a")
            if a.force_encode or not os.path.exists(dst):
                encode(src, dst, "music")
            return dict(
                id=it["id"], kind="music", title=it["title"], artist=it["artist"], category=it["category"], mood=it["mood"],
                tags=it["tags"], file=f"music/{it['id']}.m4a", bytes=os.path.getsize(dst), sha256=sha256(dst),
                license=dict(id=lic, name=LICENSES[lic][0], url=LICENSES[lic][1], evidence=evidence, verified=ev.mem.get(evidence, (None, TODAY))[1]),
                source=dict(name="FreePD.com" if it["source"] == "freepd" else "Free Music Archive", page=it["page"],
                            download=it["url"], author=it["artist"], retrieved=it.get("retrieved", TODAY),
                            pack=it.get("album"), originalSha256=h))
        with concurrent.futures.ThreadPoolExecutor(min(a.jobs, 3)) as ex:   # gentle on the Wayback Machine
            futs = {ex.submit(do_music, it): it for it in music_src["items"]}
            for f in concurrent.futures.as_completed(futs):
                try:
                    items.append(f.result())
                except Exception as e:  # noqa: BLE001
                    problems.append(str(e))
        log(f"music: {sum(1 for i in items if i['kind'] == 'music')} items")

    # ---- sound effects
    if a.only in (None, "sfx"):
        packs = sfx_src["packs"]
        pack_files, pack_lic = {}, {}
        for key, p in packs.items():
            try:
                if p["source"] == "wikimedia":
                    info = commons_info(p["commonsTitle"])
                    lic, evidence = check_commons(info, p["commonsTitle"])
                    m = info.get("extmetadata", {})
                    # authorOverride / publishedOverride: tidy names for messy Commons metadata (checked by hand)
                    p["author"] = p.get("authorOverride") or strip_html(m.get("Artist", {}).get("value", "")) or "Wikimedia Commons contributor"
                    p["published"] = p.get("publishedOverride") or strip_html(m.get("DateTimeOriginal", {}).get("value", "")) or None
                    p["url"] = info["url"]
                    path, h = fetch_original(key, info["url"], p.get("sha256"), p)
                    sha1 = hashlib.sha1(open(path, "rb").read()).hexdigest()
                    require(sha1 == info["sha1"], f"{key}: Commons sha1 mismatch")
                else:
                    lic, evidence = check_pack_page(ev, p)
                    path, h = fetch_original(key, p["url"], p.get("sha256"), p)
                    if path.endswith(".zip"):
                        z = zipfile.ZipFile(path)
                        lt = [n for n in z.namelist() if n.lower().endswith("license.txt") and "__MACOSX" not in n]
                        if p["source"] == "kenney":
                            require(lt and b"CC0" in z.read(lt[0]), f"{key}: License.txt missing or not CC0")
                pack_files[key] = (path, h); pack_lic[key] = (lic, evidence)
            except Exception as e:  # noqa: BLE001
                problems.append(f"{key}: {e}")

        def do_sfx(it):
            key = it["pack"]
            if key not in pack_files:
                raise RuntimeError(f"{it['id']}: pack {key} unavailable")
            path, h = pack_files[key]
            p = packs[key]
            src = path
            if it.get("path"):
                z = zipfile.ZipFile(path)
                data = z.read(it["path"])
                src = os.path.join(dl, "x", key, it["path"])
                os.makedirs(os.path.dirname(src), exist_ok=True)
                if not os.path.exists(src) or os.path.getsize(src) != len(data):
                    with open(src, "wb") as f:
                        f.write(data)
                h = hashlib.sha256(data).hexdigest()
            dst = os.path.join(out, "sfx", it["id"] + ".m4a")
            if a.force_encode or not os.path.exists(dst):
                encode(src, dst, "sfx", it.get("trim"))
            lic, evidence = pack_lic[key]
            name = it["name"]
            title = re.sub(r"(?<!^)([A-Z])", r" \1", name).capitalize() + (f" {it['n']}" if "n" in it else "")
            return dict(
                id=it["id"], kind="sfx", title=title, artist=p.get("author") or "", category=it["category"], tags=it["tags"],
                name=name, n=it.get("n"), file=f"sfx/{it['id']}.m4a", bytes=os.path.getsize(dst), sha256=sha256(dst),
                license=dict(id=lic, name=LICENSES[lic][0], url=LICENSES[lic][1], evidence=evidence, verified=ev.mem.get(evidence, (None, TODAY))[1]),
                source=dict(name={"kenney": "Kenney", "opengameart": "OpenGameArt", "wikimedia": "Wikimedia Commons"}[p["source"]],
                            page=p["page"], download=p["url"], author=p.get("author") or "", retrieved=p.get("retrieved", TODAY),
                            published=p.get("published"), pack=p["title"], path=it.get("path"), originalSha256=h))
        with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
            futs = [ex.submit(do_sfx, it) for it in sfx_src["items"]]
            for f in futs:
                try:
                    items.append(f.result())
                except Exception as e:  # noqa: BLE001
                    problems.append(str(e))
        log(f"sfx: {sum(1 for i in items if i['kind'] == 'sfx')} items")

    if pinned_changed:
        json.dump(music_src, open(music_src_path, "w"), indent=1, ensure_ascii=False); open(music_src_path, "a").write("\n")
        json.dump(sfx_src, open(sfx_src_path, "w"), indent=1, ensure_ascii=False); open(sfx_src_path, "a").write("\n")
        log("pinned checksums written to scripts/content/*_sources.json — review and commit them")
    if problems:
        log("\n".join("✘ " + p for p in problems))
        sys.exit(f"{len(problems)} item(s) failed")

    # keep the source-list order (music first, then sfx)
    order = {i["id"]: k for k, i in enumerate(music_src["items"] + sfx_src["items"])}
    items.sort(key=lambda i: order.get(i["id"], 1 << 30))
    for i in items:
        i["source"] = {k: v for k, v in i["source"].items() if v is not None}
        for k in [k for k, v in i.items() if v is None]:
            del i[k]
    if a.only is None:   # drop encodes of items no longer in the source lists
        keep = {i["file"] for i in items}
        for sub in ("music", "sfx"):
            for f in os.listdir(os.path.join(out, sub)):
                if f.endswith(".m4a") and f"{sub}/{f}" not in keep:
                    os.remove(os.path.join(out, sub, f))
    total = sum(i["bytes"] for i in items)
    log(f"library: {len(items)} items, {total / 1e6:.1f} MB "
        f"(music {sum(i['bytes'] for i in items if i['kind'] == 'music') / 1e6:.1f} MB, "
        f"sfx {sum(i['bytes'] for i in items if i['kind'] == 'sfx') / 1e6:.1f} MB)")
    require(total <= a.budget_mb * 1e6, f"library is {total / 1e6:.1f} MB > budget {a.budget_mb} MB")
    staging = os.path.join(out, "staging_manifest.json")
    json.dump(dict(version=1, featureVersion=0, generated=TODAY, stats={}, items=items), open(staging, "w"), indent=1, ensure_ascii=False)
    if a.no_analyze:
        log(f"staging manifest: {staging}")
        return
    cfg = "debug" if a.debug_analyzer else "release"
    log(f"building the analyser ({cfg})…")
    subprocess.run(["swift", "build", "-c", cfg, "--product", "Valse"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    binp = subprocess.run(["swift", "build", "-c", cfg, "--show-bin-path"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    final = os.path.join(out, "manifest.json")
    subprocess.run([os.path.join(binp, "Valse"), "--analyze-content", staging, out, final], check=True)
    os.makedirs(os.path.dirname(MANIFEST_OUT), exist_ok=True)
    shutil.copyfile(final, MANIFEST_OUT)
    log(f"manifest → {os.path.relpath(MANIFEST_OUT, ROOT)} ({os.path.getsize(MANIFEST_OUT) / 1e3:.0f} kB)")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit(str(e))
