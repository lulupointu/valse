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
    public func uitestSetUp(_ spec: String) async throws -> Bool {
        guard spec == "home" || spec.hasPrefix("home:") else { return false }
        let n = Int(spec.split(separator: ":").last ?? "") ?? 0
        await populateDemoLibrary(count: spec == "home" ? 0 : n)
        screen = .home
        modal = nil
        await refresh()
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
