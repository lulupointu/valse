import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MontageCore

/// Isolation for UI tests and `--home-demo` screenshots: the project library, settings, keymap and recents go to a
/// temporary folder through the volatile argument domain (never persisted, the user's real ones are untouched).
public enum HomeSandbox {
    public private(set) static var isActive = false

    @MainActor public static func isolate(uitest: Bool) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("montage-sandbox-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[MontagePaths.draftsOverrideKey] = dir.appendingPathComponent("Drafts").path
        domain[MontagePaths.supportOverrideKey] = dir.appendingPathComponent("Support").path
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        isActive = true
    }
}

extension AppModel {
    /// UI test `"project": "home"` / `"home:12"`: Home screen over a sandboxed library with N sample projects.
    /// `"home:3:crash"`: the newest project looks like it was open when the app crashed (stale session lock) → the
    /// recovery prompt. `"home:3:missing"`: the newest project references a media file that doesn't exist (relink).
    public func uitestSetUp(_ spec: String) async throws -> Bool {
        guard spec == "home" || spec.hasPrefix("home:") else { return false }
        let parts = spec.split(separator: ":").map(String.init)
        let n = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        await populateDemoLibrary(count: n)
        screen = .home
        modal = nil
        if parts.contains("missing"), let url = visibleEntries.first?.url, var p = try? ProjectPackage.load(from: url) {
            let a = MediaAsset(name: "Interview.mov", kind: .video, url: URL(fileURLWithPath: "/Volumes/Missing Drive/Interview.mov"),
                               duration: Time(8), pixelSize: .hd1080, frameRate: .fps30, hasVideo: true, hasAudio: true, contentHash: "missing-demo")
            p.media.append(a)
            try? ProjectPackage.save(p, to: url)
        }
        if parts.contains("crash"), let url = visibleEntries.first?.url {
            // a pid that can't be alive: the session "crashed"
            try? "99999999".write(to: url.appendingPathComponent(SessionLock.fileName), atomically: true, encoding: .utf8)
        }
        await refresh()
        if parts.contains("crash") { checkCrashRecovery() }
        return true
    }

    /// Fills the library with sample projects (names, durations, ratios, covers, two folders, one trashed).
    public func populateDemoLibrary(count: Int) async {
        let lib = library
        await Task.detached(priority: .userInitiated) {
            let names = ["Vacances à Biarritz", "Product launch", "Wedding teaser", "Tutorial — part 1", "Morning routine",
                         "Drone footage", "Interview Léa", "Birthday 2026", "Podcast clip", "Recipe: crêpes", "Gym vlog", "Trailer v3"]
            let ratios: [(String, Size2)] = [("16:9", .hd1080), ("9:16", Size2(1080, 1920)), ("1:1", Size2(1080, 1080)), ("4:3", Size2(1440, 1080))]
            var urls: [URL] = []
            for i in 0..<count {
                var p = Project(name: i < names.count ? names[i] : "Project \(i + 1)")
                let r = ratios[i % ratios.count]
                p.settings.canvasSize = r.1
                p.settings.aspectPreset = r.0
                let secs = Double([12, 48, 95, 7, 183, 30, 61, 240, 15, 75, 22, 130][i % 12])
                try? TimelineOps.insert(Clip(content: .text(TextContent(string: p.name)), start: 0, duration: Time(secs)), into: &p)
                p.modifiedAt = Date().addingTimeInterval(-Double(i) * 5_400 - 600)
                p.createdAt = p.modifiedAt.addingTimeInterval(-86_400)
                guard let url = try? lib.create(p) else { continue }
                Self.writeDemoCover(to: url, hue: Double(i) * 0.137, aspect: r.1.width / r.1.height)
                lib.noteOpened(url, at: p.modifiedAt)
                urls.append(url)
            }
            if count >= 6 {
                let trips = lib.createFolder(named: "Travel")
                let work = lib.createFolder(named: "Clients")
                lib.move([urls[0], urls[5]], to: trips.id)
                lib.move([urls[1], urls[3]], to: work.id)
                _ = try? lib.moveToTrash([urls[count - 1]])
            }
        }.value
        await refresh()
    }

    nonisolated static func writeDemoCover(to package: URL, hue: Double, aspect: Double) {
        let h = 320, w = Int((Double(h) * aspect / 2).rounded() * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        func color(_ dh: Double, _ s: Double, _ b: Double) -> CGColor {
            NSColor(hue: CGFloat((hue + dh).truncatingRemainder(dividingBy: 1)), saturation: s, brightness: b, alpha: 1).cgColor
        }
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(0, 0.55, 0.85), color(0.12, 0.7, 0.35)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(color(0.5, 0.3, 0.95))
        ctx.fillEllipse(in: CGRect(x: Double(w) * 0.55, y: Double(h) * 0.45, width: Double(h) * 0.35, height: Double(h) * 0.35))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.25))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 4))
        guard let img = ctx.makeImage(),
              let d = CGImageDestinationCreateWithURL(package.appendingPathComponent(ProjectPackage.coverFileName) as CFURL,
                                                      UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }

    /// `--ui-state` for screenshots: comma-separated `settings=<tab>`, `shortcuts`, `newProject`, `details=<i>`,
    /// `versions`, `relink`, `recovery`, `search=<text>`, `list`, `trash`, `folder=<i>`, `select=<i>|<j>`, `templates`.
    public func applyDebugState(_ spec: String) async {
        if !hasScanned { await refresh() }
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            let k = kv[0], v = kv.count > 1 ? kv[1] : ""
            let list = visibleEntries
            switch k {
            case "settings": modal = .settings(SettingsTab(rawValue: v) ?? .general)
            case "shortcuts": modal = .shortcuts
            case "newProject": modal = .newProject
            case "details": if let i = Int(v), i < list.count { modal = .details(list[i]) }
            case "versions": modal = .versions
            case "relink": modal = .relink
            case "recovery": modal = .recovery(Array(list.prefix(1).map(\.url)))
            case "search": isSearching = true; search = v
            case "list": setViewMode(.list)
            case "grid": setViewMode(.grid)
            case "trash": scope = .trash
            case "recents": scope = .recents
            case "templates": section = .templates
            case "folder": if let i = Int(v), i < folders.count { scope = .folder(folders[i].id) }
            case "select": selectedIDs = Set(v.split(separator: "|").compactMap { Int($0) }.filter { $0 < list.count }.map { list[$0].id })
            case "editor": screen = .editor
            default: break
            }
        }
    }
}

extension AppModel {
    /// `app` section of the UI-test state dump (docs/TESTING.md).
    public func stateDump() -> [String: Any] {
        let scopeName: String = {
            switch scope {
            case .all: return "all"
            case .recents: return "recents"
            case .trash: return "trash"
            case .folder(let id): return "folder:" + (folders.first { $0.id == id }?.name ?? "?")
            }
        }()
        let visible = visibleEntries
        let s = preferences.settings
        let km = Keymap.shared
        return [
            "screen": screen == .home ? "home" : "editor",
            "modal": modal?.id ?? "",
            "section": section == .projects ? "projects" : "templates",
            "scope": scopeName,
            "search": isSearching ? search : "",
            "sort": sort.rawValue, "ascending": ascending,
            "viewMode": viewMode.rawValue,
            "selected": visible.filter { selectedIDs.contains($0.id) }.map(\.name),
            "renaming": entries.first { $0.id == renamingID }?.name ?? "",
            "projects": visible.map(\.name),
            "entries": entries.map { e in
                ["name": e.name, "folder": folders.first { $0.id == e.folderID }?.name ?? "", "trashed": e.trashedAt != nil] as [String: Any]
            },
            "folders": folders.map(\.name),
            "trashCount": trashCount,
            "projectName": store.projectName,
            "renderedRanges": store.renderedPreviewRanges().map { [$0.start.seconds, $0.end.seconds] },
            "settings": [
                "language": L10n.shared.languagePreference, "previewQuality": s.previewQuality, "useProxies": s.useProxies,
                "proxyPolicy": s.proxyPolicy, "imageDuration": s.imageDuration, "stepFrames": s.stepFrames,
                "freezeDuration": s.freezeDuration, "exportCodec": s.exportCodec, "exportResolution": s.exportResolution,
                "autoRender": s.autoRender, "renderCacheLimitGB": s.renderCacheLimitGB, "hardwareEncoding": s.hardwareEncoding,
                "cacheAutoDeleteDays": s.cacheAutoDeleteDays ?? 0,
            ] as [String: Any],
            "keymap": [
                "preset": km.preset.rawValue,
                "overrides": km.overrides.count,
                "bindings": Dictionary(uniqueKeysWithValues: km.entries.map { ($0.id, km.binding(for: $0.id)?.display ?? "") }),
            ] as [String: Any],
        ]
    }
}
