import UniformTypeIdentifiers
import ValseCore

extension ProjectPackage {
    /// Open panels: `.valse` packages and the `.montage` ones saved before the rename (Info.plist exports
    /// `fr.valse.project` and imports `fr.montage.project`; unbundled dev builds match by extension).
    public static var contentTypes: [UTType] {
        let declared = [typeIdentifier, legacyTypeIdentifier].compactMap { UTType($0) }
        let byExtension = fileExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .package) }
        return declared + byExtension
    }
}
