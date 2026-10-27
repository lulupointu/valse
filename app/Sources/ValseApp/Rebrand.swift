import AppKit
import ValseCore
import ValseEffects
import ValseEngine

/// The bridge update (docs/RELEASING.md "The Montage → Valse bridge") installs Valse where Montage was, under the old
/// bundle name `Montage.app`: Sparkle keeps the installed path, and pre-rename copies only accept an archive holding
/// `Montage.app`. At its first launch from there, Valse renames its own bundle to `Valse.app` in the same folder and
/// starts again from the new path, before anything has loaded a resource from the old one.
///
/// Skipped silently (the app then just runs from `Montage.app`; later updates still find it by bundle id) when: not a
/// Valse .app bundle, already named otherwise, a `Valse.app` already exists next to it, the folder isn't writable, the
/// app runs translocated (Gatekeeper's read-only copy), or this is a test / tooling launch (`--uitest`, `--snapshot`,
/// `--offscreen`, `--background`…), unless `VALSE_SELF_RENAME=1` (scripts/updater_e2e.sh).
enum BundleRename {
    static let toolingFlags: Set<String> = ["--uitest", "--snapshot", "--offscreen", "--background", "--home-demo",
                                           "--quit-after", "--imgdiff", "--analyze-content", "--check-project",
                                           "--ui-state", "--window-id-file", "--player-state"]

    static func isTooling(_ arguments: [String]) -> Bool { arguments.dropFirst().contains { toolingFlags.contains($0) } }

    /// Renames and relaunches (does not return) when it applies; returns otherwise.
    static func relaunchFromValseBundleIfNeeded(arguments: [String] = CommandLine.arguments,
                                                environment: [String: String] = ProcessInfo.processInfo.environment) {
        let forced = environment["VALSE_SELF_RENAME"] == "1"
        if !forced, isTooling(arguments) { return }
        let source = Bundle.main.bundleURL
        guard let target = target(bundle: source, bundleID: Bundle.main.bundleIdentifier),
              Darwin.rename(source.path, target.path) == 0 else { return }
        let exe = target.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(Bundle.main.executableURL?.lastPathComponent ?? "Valse")
        if forced {
            // tooling (scripts/updater_e2e.sh): same process, arguments and environment, from the new path
            var cargs: [UnsafeMutablePointer<CChar>?] = ([exe.path] + arguments.dropFirst()).map { strdup($0) } + [nil]
            execv(exe.path, &cargs)
            _ = Darwin.rename(target.path, source.path)   // exec failed: back to where this process started
            return
        }
        // a normal launch (Finder, Dock, Sparkle's relaunch): Launch Services starts the renamed app, this one exits
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", target.path] + (arguments.count > 1 ? ["--args"] + arguments.dropFirst() : [])
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0 { exit(0) }
        }
        _ = Darwin.rename(target.path, source.path)   // couldn't relaunch: keep running from where this process started
    }

    /// `…/Montage.app` of a Valse bundle → `…/Valse.app`, when the rename is possible; nil otherwise.
    static func target(bundle: URL, bundleID: String?) -> URL? {
        guard bundle.pathExtension == "app", bundle.lastPathComponent == LegacyNames.appName + ".app",
              let id = bundleID, id.hasPrefix("fr.valse.") else { return nil }
        let parent = bundle.deletingLastPathComponent()
        guard !parent.path.contains("/AppTranslocation/") else { return nil }
        let target = parent.appendingPathComponent("Valse.app", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path), access(parent.path, W_OK) == 0 else { return nil }
        return target
    }
}

/// Runs `RebrandMigration` (settings, folders) and the keychain migration once, at the very start of a normal launch.
enum RebrandLaunch {
    static func migrateIfNeeded(arguments: [String] = CommandLine.arguments,
                                environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard Bundle.main.bundleURL.pathExtension == "app", let id = Bundle.main.bundleIdentifier, id.hasPrefix("fr.valse.") else { return }
        // scripts/updater_e2e.sh test copies: only inside their sandboxed home (CFFIXED_USER_HOME), never the real one
        let test = environment["VALSE_UPDATER_TEST"] == "1" && !(environment["CFFIXED_USER_HOME"] ?? "").isEmpty
        if id != "fr.valse.Valse" || BundleRename.isTooling(arguments) { guard test else { return } }
        guard !UserDefaults.standard.bool(forKey: RebrandMigration.doneKey) else { return }
        let legacyDomain = (test ? environment["VALSE_LEGACY_DEFAULTS_DOMAIN"] : nil) ?? LegacyNames.bundleID
        let report = RebrandMigration.run(.init(
            home: FileManager.default.homeDirectoryForCurrentUser, defaults: .standard, domain: id, legacyDomain: legacyDomain,
            legacyAppRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: legacyDomain).isEmpty }))
        let keys = KeychainSecretStore.migrateLegacyItems()
        EngineLog.info("rename migration: moved \(report.moved), kept \(report.kept), \(report.copiedKeys) settings, "
                       + "\(keys.count) keychain item(s), done: \(report.done)")
    }
}

/// `--check-project <package>`: loads a project the way the editor does (old content IDs mapped, moved media found) and
/// prints a one-line JSON verdict; exit 0 when it loaded (scripts/updater_e2e.sh checks a pre-rename `.montage`).
enum ProjectCheckCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let path = args.first else {
            FileHandle.standardError.write(Data("usage: Valse --check-project <package>\n".utf8))
            return 2
        }
        func emit(_ o: [String: Any]) {
            let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
            print(String(decoding: d, as: UTF8.self))
        }
        do {
            let p = try ProjectPackage.load(from: URL(fileURLWithPath: path))
            let json = try JSONSerialization.jsonObject(with: ProjectPackage.encoder().encode(p))
            var strings: [String] = []
            collect(json, into: &strings)
            let known = Set(Registries.effects.all.map(\.id) + Registries.transitions.all.map(\.id)
                + Registries.animations.all.map(\.id) + Registries.stickers.all.map(\.id) + Registries.textStyles.all.map(\.id)
                + Registries.textBubbles.all.map(\.id) + Registries.textTemplates.all.map(\.id)
                + Registries.captionTemplates.all.map(\.id) + (SpeedCurvePreset.all + SpeedCurvePreset.velocity).map(\.id)
                + VoiceEffects.all.map(\.id))
            let legacy = Set(strings.filter { $0.hasPrefix(LegacyNames.appName.lowercased() + ".") }).sorted()
            let unknown = Set(strings.filter { $0.hasPrefix("valse.") && !known.contains($0) }).sorted()
            let missing = p.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.url.path)
            emit(["ok": true, "clips": p.timeline.tracks.reduce(0) { $0 + $1.clips.count }, "media": p.media.count,
                  "legacyIDs": legacy, "unknownIDs": unknown, "missingMedia": missing])
            return 0
        } catch {
            emit(["ok": false, "error": String(describing: error)])
            return 1
        }
    }

    static func collect(_ v: Any, into out: inout [String]) {
        switch v {
        case let s as String: out.append(s)
        case let a as [Any]: a.forEach { collect($0, into: &out) }
        case let d as [String: Any]: for (k, x) in d { out.append(k); collect(x, into: &out) }
        default: break
        }
    }
}
