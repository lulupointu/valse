import Foundation
import IOKit.ps

/// System conditions under which background work does not start (and pauses): PERF-CAPTIONS-2.
public enum BackgroundConditions {
    public enum Blocker: String, Sendable { case thermal, lowPower, battery }

    /// On battery below this charge, no background transcription: it can run later on power, and the user's battery
    /// matters more than captions being instant then. Half charge leaves the Mac well clear of macOS's own low-battery
    /// territory (warnings and Low Power Mode suggestions at 20 % / 10 %).
    public static let minBatteryFraction = 0.5

    public static func current() -> Blocker? {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return .thermal }
        if info.isLowPowerModeEnabled { return .lowPower }
        if let b = cachedBattery(), b.onBattery, b.fraction < minBatteryFraction { return .battery }
        return nil
    }

    /// `battery()` read at most every 10 s (the scheduler polls 4× a second while a pass runs).
    private static func cachedBattery() -> (onBattery: Bool, fraction: Double)? {
        let t = CaptionTimings.now()
        return batteryLock.withLock {
            if let c = batteryCache, t - c.at < 10 { return c.value }
            let v = battery()
            batteryCache = (t, v)
            return v
        }
    }
    private static let batteryLock = NSLock()
    nonisolated(unsafe) private static var batteryCache: (at: Double, value: (onBattery: Bool, fraction: Double)?)?

    /// Internal battery: on battery power + charge 0…1 (nil: desktop Mac / no battery).
    public static func battery() -> (onBattery: Bool, fraction: Double)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (onBattery, Double(cur) / Double(max))
        }
        return nil
    }
}
