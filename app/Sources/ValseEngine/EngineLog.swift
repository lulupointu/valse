import Foundation
import os
import ValseCore

/// Engine logging (unified logging, subsystem "fr.valse"). `VALSE_DEBUG=1` also mirrors to stderr.
public enum EngineLog {
    public static let subsystem = "fr.valse"
    static let logger = Logger(subsystem: subsystem, category: "engine")
    static let mirror = ProcessInfo.processInfo.environment["VALSE_DEBUG"] != nil

    public static func info(_ s: String) {
        logger.info("\(s, privacy: .public)")
        if mirror { FileHandle.standardError.write(Data(("[valse] " + s + "\n").utf8)) }
    }
    public static func error(_ s: String) {
        logger.error("\(s, privacy: .public)")
        FileHandle.standardError.write(Data(("[valse:error] " + s + "\n").utf8))
    }
}

public enum EngineResources {
    public static let bundle: Bundle = ResourceBundleLocator.find("Valse_ValseEngine", fallback: .module)
    public static func register() { L10n.shared.register(bundle) }
}
