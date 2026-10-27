import Foundation
import MontageCore

/// "Package logs & drafts" (SE-018): one zip a user can attach to a bug report — this session's Montage log
/// (OSLogStore, subsystem fr.montage), the environment report (SE-014), app settings, Montage crash reports, and
/// optionally the open project's `project.json` (no media). Built locally; nothing is sent anywhere.
public enum SupportPackage {
    public struct Contents: Sendable {
        public var projectJSON: Data?
        public var projectName: String?
        public var settingsURL: URL? = AppSettings.defaultURL
        public var crashReportsDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        public var includeLog = true
        public init(projectJSON: Data? = nil, projectName: String? = nil) { self.projectJSON = projectJSON; self.projectName = projectName }
    }

    /// Writes `Valse support <date>.zip` into `directory` and returns its URL.
    public static func build(_ c: Contents, into directory: URL, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Valse support \(f.string(from: date))"
        let staging = fm.temporaryDirectory.appendingPathComponent("valse-support-\(UUID().uuidString)").appendingPathComponent(name)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }

        let env = EnvironmentProbe.run()
        var info = "Valse support package — \(f.string(from: date))\n"
        info += "Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")\n\n"
        for ch in env.checks { info += "\(ch.id): \(ch.value) [\(ch.status.rawValue)]\n" }
        try Data(info.utf8).write(to: staging.appendingPathComponent("environment.txt"))
        if c.includeLog { try Data(sessionLog().utf8).write(to: staging.appendingPathComponent("valse.log")) }
        if let s = c.settingsURL, fm.fileExists(atPath: s.path) { try? fm.copyItem(at: s, to: staging.appendingPathComponent("settings.json")) }
        if let dir = c.crashReportsDirectory, let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let crashes = items.filter { $0.lastPathComponent.hasPrefix("Valse") || $0.lastPathComponent.hasPrefix("Montage") }
                .sorted { modified($0) > modified($1) }
                .prefix(5)
            if !crashes.isEmpty {
                let cd = staging.appendingPathComponent("crashes")
                try fm.createDirectory(at: cd, withIntermediateDirectories: true)
                for u in crashes { try? fm.copyItem(at: u, to: cd.appendingPathComponent(u.lastPathComponent)) }
            }
        }
        if let pj = c.projectJSON {
            let pd = staging.appendingPathComponent("project")
            try fm.createDirectory(at: pd, withIntermediateDirectories: true)
            try pj.write(to: pd.appendingPathComponent("project.json"))
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let zip = directory.appendingPathComponent(name).appendingPathExtension("zip")
        try? fm.removeItem(at: zip)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zip.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: zip.path) else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// This process's Montage log lines (last 2 h), read with `/usr/bin/log show` in a child process: enumerating
    /// OSLogStore in-process can stall the process's own logging (AVFoundation decoders log a lot) and deadlocked
    /// concurrent media readers in the test suite.
    static func sessionLog() -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["show", "--style", "compact", "--last", "2h", "--predicate",
                       "subsystem == \"fr.montage\" AND processID == \(ProcessInfo.processInfo.processIdentifier)"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "(log unavailable)\n" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "(no Valse log entries in this session)\n" : text
    }
}
