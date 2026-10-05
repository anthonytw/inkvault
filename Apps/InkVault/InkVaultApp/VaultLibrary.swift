import Age
import Foundation
import InkVault
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// A `.inkvault` folder, shown by Files as one document (a package). Declared
    /// as an exported type in `InkVaultInfo.plist`.
    static let inkVault = UTType(exportedAs: "io.github.anthonytw.inkvault.vault", conformingTo: .package)

    /// What the "open vault" pickers accept: vault packages, and plain folders
    /// (older vaults, or ones not named `.inkvault`).
    static var vaultPickerTypes: [UTType] { [.inkVault, .folder] }
}

/// Turns whatever the user picked into the vault folder.
enum VaultLocator {
    enum LocatorError: Error, Equatable, CustomStringConvertible {
        case severalVaults([String])

        var description: String {
            switch self {
            case .severalVaults(let names):
                return "That folder holds several vaults (\(names.joined(separator: ", "))). Choose one of them."
            }
        }
    }

    /// The vault folder for `picked`:
    /// - a folder or file inside a vault (`vault.json`, `keys/…`, `notes/…`):
    ///   the enclosing vault folder;
    /// - a folder with a `vault.json`: itself;
    /// - a folder holding exactly one `.inkvault` folder: that folder;
    /// - anything else: `picked` unchanged (opening it reports the problem).
    ///
    /// - Throws: `LocatorError.severalVaults` for a folder holding more than one vault.
    static func resolve(_ picked: URL, fileManager fm: FileManager = .default) throws -> URL {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: picked.path, isDirectory: &isDir) else { return picked }
        func isVault(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("vault.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(CloudPlaceholder.placeholderName(for: "vault.json")).path)
        }
        // At or inside a vault: vault.json is at most `notes/<id>/<file>` deep.
        var candidate = isDir.boolValue ? picked : picked.deletingLastPathComponent()
        for _ in 0..<4 {
            if isVault(candidate) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        guard isDir.boolValue else { return picked }
        let inside = VaultLibrary.vaults(in: picked)
        if inside.count == 1 { return inside[0] }
        if inside.count > 1 { throw LocatorError.severalVaults(inside.map(\.lastPathComponent)) }
        return picked
    }
}

/// A vault the app has opened before, reachable through a bookmark.
struct RecentVault: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Folder name without `.inkvault`, for display.
    var name: String
    /// Bookmark of the vault folder. On iOS a bookmark made from a
    /// document-picker URL carries its security scope.
    var bookmark: Data
    var lastOpened: Date
}

/// Security-scoped bookmarks of vault folders.
enum VaultBookmark {
    struct Resolved {
        var url: URL
        /// A fresh bookmark when the stored one was stale.
        var refreshed: Data?
    }

    /// Bookmarks `url`. Access to it (or a parent) must be active.
    static func make(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark; when it is stale, tries to re-save it.
    static func resolve(_ data: Data) throws -> Resolved {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale else { return Resolved(url: url, refreshed: nil) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Resolved(url: url, refreshed: try? make(for: url))
    }
}

/// What the "new vault" form produces.
struct NewVaultRequest: Sendable {
    enum KeySource: Sendable {
        /// Generate an X25519 key on this device.
        case generate
        /// Encrypt to an existing `age1…` recipient; this device gets no key.
        case recipient(String)
    }

    var name: String
    var keySource: KeySource
    /// Wrap the generated key with this passphrase into `keys/` (generate only).
    var passphrase: String?
}

/// The outcome of creating a vault.
struct CreatedVault: Sendable {
    var url: URL
    /// The new secret key (`AGE-SECRET-KEY-1…`) when one was generated; the
    /// user must save it, nothing else holds it unless a passphrase wrapped it.
    var secretKey: String?
    /// The recents entry saved for it, whose bookmark carries the access the
    /// app needs to reopen it; nil when saving it failed.
    var recentID: UUID?
}

/// Recent vaults, vault creation, and the places vaults live.
@MainActor
@Observable
final class VaultLibrary {
    enum LibraryError: Error, Equatable, CustomStringConvertible {
        case invalidName
        case invalidRecipient
        case passphraseNeedsGeneratedKey
        case cannotResolve(name: String)

        var description: String {
            switch self {
            case .invalidName: return "Give the vault a name without slashes, leading dots or control characters."
            case .invalidRecipient: return "That text is not an age1… recipient."
            case .passphraseNeedsGeneratedKey: return "A passphrase can only wrap a key generated on this device."
            case .cannotResolve(let name):
                return "“\(name)” can't be found any more. It may have been moved or deleted, or access to it expired. Choose its folder again."
            }
        }
    }

    static let maxRecents = 10

    private(set) var recents: [RecentVault] = []
    let storeURL: URL

    init(storeURL: URL = VaultLibrary.defaultStoreURL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([RecentVault].self, from: data) {
            recents = list
        }
    }

    // MARK: - Places

    /// `Application Support/InkVault/recents.json`.
    static var defaultStoreURL: URL { supportDirectory.appendingPathComponent("recents.json") }

    private static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("InkVault", isDirectory: true)
    }

    /// The app container's Documents folder, where "On This Device" vaults live.
    static var onDeviceFolder: URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// The `.inkvault` folders directly inside `folder`, sorted by name.
    nonisolated static func vaults(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { $0.pathExtension == "inkvault" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Recents

    /// Records that the vault at `url` was opened. Access to it must be active.
    @discardableResult
    func remember(_ url: URL) throws -> RecentVault {
        let data = try VaultBookmark.make(for: url)
        let path = url.standardizedFileURL.path
        recents.removeAll { entry in
            (try? VaultBookmark.resolve(entry.bookmark))?.url.standardizedFileURL.path == path
        }
        let entry = RecentVault(id: UUID(), name: Self.displayName(of: url), bookmark: data, lastOpened: Date())
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        save()
        return entry
    }

    /// Resolves a recent entry to a URL, re-saving a stale bookmark. A
    /// bookmark that no longer resolves is dropped from the list.
    func resolve(_ entry: RecentVault) throws -> URL {
        do {
            let resolved = try VaultBookmark.resolve(entry.bookmark)
            if let fresh = resolved.refreshed, let i = recents.firstIndex(where: { $0.id == entry.id }) {
                recents[i].bookmark = fresh
                save()
            }
            return resolved.url
        } catch {
            forget(entry)
            throw LibraryError.cannotResolve(name: entry.name)
        }
    }

    func forget(_ entry: RecentVault) {
        recents.removeAll { $0.id == entry.id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: storeURL, options: .atomic)
        } catch {
            // Recents are a convenience; a failed save only loses the list.
        }
    }

    nonisolated static func displayName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Creating

    /// The folder name for a vault called `name`: `<name>.inkvault`.
    nonisolated static func folderName(for name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = trimmed.isEmpty || trimmed.hasPrefix(".") || trimmed.hasSuffix(".inkvault")
            || trimmed.contains { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline }
        if bad { throw LibraryError.invalidName }
        return trimmed + ".inkvault"
    }

    /// Creates a vault named `request.name` inside `parent`. For a folder from
    /// the document picker, the caller keeps the vault's own bookmark
    /// (`remember`) while access to `parent` is active, which this does.
    ///
    /// Runs the blocking work (scrypt, file I/O) off the main actor.
    func create(_ request: NewVaultRequest, in parent: URL) async throws -> CreatedVault {
        let folder = try Self.folderName(for: request.name)
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }
        var created = try await Task.detached(priority: .userInitiated) {
            // In iCloud Drive, a coordinated write so the new folder is uploaded.
            let target = parent.appendingPathComponent(folder, isDirectory: true)
            return try CloudVault.coordinatedWrite(CloudVault.isUbiquitous(parent) ? target : nil) {
                try Self.createVault(request, folder: folder, in: parent)
            }
        }.value
        created.recentID = try? remember(created.url).id
        return created
    }

    /// Synchronous core of `create` (testable without the main actor).
    nonisolated static func createVault(_ request: NewVaultRequest, folder: String, in parent: URL) throws -> CreatedVault {
        let url = parent.appendingPathComponent(folder, isDirectory: true)
        switch request.keySource {
        case .generate:
            let identity = X25519Identity()
            let vault = try Vault.create(at: url, recipients: [identity.recipient], labels: ["This device"],
                                         identities: [identity])
            if let passphrase = request.passphrase, !passphrase.isEmpty {
                try vault.writeIdentityFile(identity, passphrase: passphrase)
            }
            return CreatedVault(url: url, secretKey: identity.string)
        case .recipient(let text):
            guard request.passphrase?.isEmpty ?? true else { throw LibraryError.passphraseNeedsGeneratedKey }
            let recipient: X25519Recipient
            do { recipient = try X25519Recipient(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) } catch {
                throw LibraryError.invalidRecipient
            }
            _ = try Vault.create(at: url, recipients: [recipient])
            return CreatedVault(url: url, secretKey: nil)
        }
    }
}
