import Foundation

/// VideoToolbox / media-services failures that come from the machine's state (hardware codec sessions exhausted or
/// reset, allocation pressure), not from the content or the settings: retrying the same work later succeeds.
public enum VideoToolboxErrors {
    /// OSStatus codes (VTErrors.h, AVError) treated as transient.
    public static let transientCodes: Set<Int> = [
        -12902,   // kVTParameterErr: seen from the HEVC hardware encoder under saturation (FLAKY-SYS-UNIT)
        -12903,   // kVTInvalidSessionErr (session torn down by the system)
        -12904,   // kVTAllocationFailedErr
        -12907,   // kVTCouldNotCreateInstanceErr
        -12911,   // kVTVideoDecoderMalfunctionErr
        -12912,   // kVTVideoEncoderMalfunctionErr
        -12913,   // kVTVideoDecoderNotAvailableNowErr
        -12915,   // kVTVideoEncoderNotAvailableNowErr
        -11819,   // AVErrorMediaServicesWereReset
        -11847,   // AVErrorOperationInterrupted
    ]

    /// Whether `error` or any error under it (NSUnderlyingErrorKey chain) carries a transient code.
    public static func isTransient(_ error: Error) -> Bool {
        var e: NSError? = error as NSError
        var depth = 0
        while let x = e, depth < 8 {
            if transientCodes.contains(x.code), x.domain == NSOSStatusErrorDomain || x.domain == "AVFoundationErrorDomain" { return true }
            e = x.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
