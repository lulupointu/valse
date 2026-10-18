@preconcurrency import AVFoundation
import Foundation
import MontageCore

/// AVFoundation colour tags of a project colour space (video composition, writer colour properties).
public struct ColorTags: Sendable {
    public let primaries: String
    public let transfer: String
    public let matrix: String

    public init(_ space: ProjectColorSpace) {
        switch space {
        case .sdr709:
            primaries = AVVideoColorPrimaries_ITU_R_709_2
            transfer = AVVideoTransferFunction_ITU_R_709_2
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        case .hdrHLG, .hdrPQ:
            primaries = AVVideoColorPrimaries_ITU_R_2020
            transfer = space == .hdrHLG ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ
            matrix = AVVideoYCbCrMatrix_ITU_R_2020
        }
    }

    /// `AVVideoColorPropertiesKey` dictionary.
    public var properties: [String: Any] {
        [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }
}
