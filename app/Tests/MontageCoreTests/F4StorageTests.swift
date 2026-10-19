import Testing
import Foundation
@testable import MontageCore

/// F4 PM-009: external-drive warnings for the project Save-to folder.
@Suite(.serialized) struct StorageLocationTests {
    @Test func classifiesVolumeFlags() {
        #expect(StorageLocation.classify(flags: .init(isInternal: true, isLocal: true), fallbackName: "x") == .internalDisk)
        #expect(StorageLocation.classify(flags: .init(isInternal: false, isLocal: true, name: "SSD"), fallbackName: "x") == .external(name: "SSD"))
        #expect(StorageLocation.classify(flags: .init(isInternal: true, isLocal: true, isRemovable: true), fallbackName: "Card") == .external(name: "Card"))
        #expect(StorageLocation.classify(flags: .init(isInternal: nil, isLocal: true, isEjectable: true, name: "USB"), fallbackName: "x") == .external(name: "USB"))
        #expect(StorageLocation.classify(flags: .init(isInternal: false, isLocal: false, name: "NAS"), fallbackName: "x") == .network(name: "NAS"))
        #expect(StorageLocation.classify(flags: .init(), fallbackName: "x") == .internalDisk)
    }

    @Test func homeFolderIsInternalAndMissingDriveIsUnavailable() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Montage/not-created-yet")
        #expect(StorageLocation.of(home) == .internalDisk)
        #expect(!StorageLocation.of(home).needsWarning)
        let gone = URL(fileURLWithPath: "/Volumes/Montage No Such Drive \(UUID().uuidString.prefix(6))/Projects")
        let l = StorageLocation.of(gone)
        #expect(l.isUnavailable)
        #expect(l.driveName?.hasPrefix("Montage No Such Drive") == true)
        #expect(StorageLocation.volumeRoot(of: gone)?.path.hasPrefix("/Volumes/Montage No Such Drive") == true)
        #expect(StorageLocation.volumeRoot(of: home) == nil)
    }

    @Test func disconnectedSaveFolderFallsBackToTheDefault() {
        // volatile argument domain: never persisted, even if the test dies half-way
        let d = UserDefaults.standard
        let saved = d.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { d.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        func set(_ p: String) { var dom = saved; dom[MontagePaths.draftsOverrideKey] = p; d.setVolatileDomain(dom, forName: UserDefaults.argumentDomain) }
        let off = "/Volumes/Montage Unplugged \(UUID().uuidString.prefix(6))/Montage"
        set(off)
        #expect(MontagePaths.draftsDirectory.standardizedFileURL == MontagePaths.defaultDraftsDirectory.standardizedFileURL)
        #expect(MontagePaths.configuredDraftsWarning?.location.isUnavailable == true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("f4-drafts-\(UUID().uuidString)")
        set(tmp.path)
        #expect(MontagePaths.draftsDirectory.standardizedFileURL.path == tmp.standardizedFileURL.path)
        #expect(MontagePaths.configuredDraftsWarning == nil)
    }
}
