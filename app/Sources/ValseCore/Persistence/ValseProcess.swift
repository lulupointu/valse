import Foundation

/// What kind of process this is.
public enum ValseProcess {
    /// A unit-test process (`swift test` runs the test bundle in `swiftpm-testing-helper` / `xctest`). Not the app
    /// under a UI script (`--uitest`), which is the real app.
    public static let isUnitTest: Bool = {
        let name = ProcessInfo.processInfo.processName
        if name == "swiftpm-testing-helper" || name == "xctest" { return true }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return Bundle.main.bundlePath.hasSuffix(".xctest")
    }()
}
