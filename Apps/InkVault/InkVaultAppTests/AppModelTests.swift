import Age
import Foundation
import InkVault
import Testing
@testable import InkVaultApp

/// AppModel against the committed fixture vault (`Tests/InkVaultTests/Fixtures`,
/// copied into this bundle as a folder reference). See its README for contents.
@MainActor
struct AppModelTests {
    static let lecture = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let deleted = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// A private copy of the fixture, so no test can touch the bundled one.
    static func fixtureVault() throws -> (vault: URL, key: URL) {
        let bundle = Bundle(for: BundleToken.self)
        guard let fixtures = bundle.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Fixtures missing from test bundle"])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = dir.appendingPathComponent("sample.inkvault")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("sample.inkvault"), to: vault)
        return (vault, fixtures.appendingPathComponent("sample.key"))
    }

    @Test func opensLockedThenUnlocksWithKeyFile() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        #expect(model.phase == .locked)
        #expect(model.vaultName == "sample")
        #expect(model.notes.isEmpty)

        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.phase == .unlocked)
        #expect(model.notes.map(\.id) == [Self.deleted, Self.lecture])   // sorted by title
        let lecture = try #require(model.notes.first { $0.id == Self.lecture })
        #expect(lecture.title == "Fixture lecture")
        #expect(lecture.tags == ["fixture"])
        #expect(lecture.pages == 2)
        #expect(lecture.strokes == 4)
        #expect(lecture.problem == nil)
    }

    @Test func sidebarFiltersLiveAndDeletedNotes() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))

        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        #expect(model.tags == ["fixture"])
        #expect(model.notebooks.isEmpty)
        model.sidebarSelection = .tag("fixture")
        #expect(model.visibleNotes.map(\.id) == [Self.lecture])
        model.sidebarSelection = .tag("nope")
        #expect(model.visibleNotes.isEmpty)
        model.sidebarSelection = .deleted
        #expect(model.visibleNotes.map(\.id) == [Self.deleted])
        model.selectedNoteID = Self.lecture
        #expect(model.selectedNote?.title == "Fixture lecture")
    }

    @Test func unlocksWithStoredKeyPassphrase() async throws {
        let (url, _) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        await #expect(throws: AppModel.ModelError.passphraseMatchesNoKey) {
            try await model.unlock(passphrase: "wrong")
        }
        #expect(model.phase == .locked)
        try await model.unlock(passphrase: "inkvault-test")
        #expect(model.phase == .unlocked)
        #expect(model.notes.count == 2)
    }

    @Test func rejectsGarbageAndForeignKeys() async throws {
        let (url, _) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        await #expect(throws: AppModel.ModelError.notAnIdentity) {
            try await model.unlock(identityText: "not a key")
        }
        let stranger = IdentityFile.render(.init(), created: Date())
        await #expect(throws: VaultError.self) {
            try await model.unlock(identityText: stranger)
        }
        #expect(model.phase == .locked)
    }

    @Test func closeForgetsEverything() async throws {
        let (url, key) = try Self.fixtureVault()
        let model = AppModel()
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.close()
        #expect(model.phase == .noVault)
        #expect(model.notes.isEmpty)
        #expect(model.vaultURL == nil)
        await #expect(throws: AppModel.ModelError.noVaultOpen) { try await model.reload() }
    }

    @Test func openingAFolderThatIsNotAVaultFails() async throws {
        let model = AppModel()
        await #expect(throws: VaultError.self) {
            try await model.openVault(at: FileManager.default.temporaryDirectory)
        }
        #expect(model.phase == .noVault)
    }
}

private final class BundleToken {}
