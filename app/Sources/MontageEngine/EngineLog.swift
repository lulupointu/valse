import Foundation
import os
import MontageCore

/// Engine logging (unified logging, subsystem "fr.montage"). `MONTAGE_DEBUG=1` also mirrors to stderr.
public enum EngineLog {
    static let logger = Logger(subsystem: "fr.montage", category: "engine")
    static let mirror = ProcessInfo.processInfo.environment["MONTAGE_DEBUG"] != nil

    public static func info(_ s: String) {
        logger.info("\(s, privacy: .public)")
        if mirror { FileHandle.standardError.write(Data(("[montage] " + s + "\n").utf8)) }
    }
    public static func error(_ s: String) {
        logger.error("\(s, privacy: .public)")
        FileHandle.standardError.write(Data(("[montage:error] " + s + "\n").utf8))
    }
}

public enum EngineResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Montage_MontageEngine", fallback: .module)
    public static func register() { L10n.shared.register(bundle) }
}
