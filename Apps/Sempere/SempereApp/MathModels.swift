import Foundation
import Observation
import Sempere
import SempereRender

/// The "Convert to Math" setting (per device, off by default): the Insert
/// menu's "Equation from Handwriting" appears only when it is on and a
/// model is installed (docs/attachments.md §14 G1 part 2).
enum MathRecognitionPreference {
    static let key = "Sempere.mathRecognition"
    static let defaultValue = false

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Handwritten-math models on this device: which can be had
/// (`MathModelCatalog`, plus a local folder in DEBUG scripted runs), which
/// is installed (`MathModelStore`, Application Support/Sempere/MathModels,
/// excluded from backups), downloading one (every file checked against the
/// manifest the catalogue pins before anything is used) and the loaded
/// recogniser. Device-wide: models are not vault data.
@MainActor
@Observable
final class MathModels {
    static let shared = MathModels()

    enum Status: Equatable {
        case notInstalled
        case downloading(done: Int64, total: Int64)
        case installed
        case failed(String)
    }

    /// Where models are kept.
    let root: URL
    /// The models offered, best first.
    let catalog: [MathModelCatalogEntry]
    private(set) var status: [String: Status] = [:]
    /// Tests: used instead of loading a model.
    @ObservationIgnored var recognizerOverride: (any MathRecognizing)?
    /// A model folder used as is (DEBUG `SEMPERE_DEBUG_MATH_MODEL`; checked like a download).
    @ObservationIgnored private let localFolder: URL?
    @ObservationIgnored private var loaded: (id: String, recognizer: any MathRecognizing)?
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let session: MathModelFetching

    init(root: URL = MathModels.defaultRoot, catalog: [MathModelCatalogEntry] = MathModelCatalog.entries,
         localFolder: URL? = MathModels.debugFolder, session: MathModelFetching = URLSessionModelFetcher()) {
        self.root = root
        self.catalog = catalog
        self.localFolder = localFolder
        self.session = session
        refresh()
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sempere/MathModels", isDirectory: true)
    }

    /// `SEMPERE_DEBUG_MATH_MODEL` (DEBUG builds): a converted model folder to
    /// use without a catalogue entry (`~/` is the app's data container).
    nonisolated static var debugFolder: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["SEMPERE_DEBUG_MATH_MODEL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst(1) : path, isDirectory: true)
        #else
        return nil
        #endif
    }

    /// Whether a model can read ink now (installed, or the test override).
    var isAvailable: Bool {
        recognizerOverride != nil || localFolder != nil || status.values.contains(.installed)
    }

    /// Looks at what is installed.
    func refresh() {
        for entry in catalog where downloads[entry.id] == nil {
            status[entry.id] = MathModelStore.installed(entry, root: root) == nil ? .notInstalled : .installed
        }
    }

    /// Downloads `entry` into the store: its manifest (which must hash to the
    /// entry's), then every file (each must match the manifest), then installs.
    func download(_ entry: MathModelCatalogEntry) {
        guard downloads[entry.id] == nil else { return }
        status[entry.id] = .downloading(done: 0, total: entry.downloadBytes)
        let root = self.root, session = self.session
        let progress: @Sendable (Int64) -> Void = { [weak self] done in
            let models = self
            Task { @MainActor in models?.progressed(entry, done: done) }
        }
        downloads[entry.id] = Task { [weak self] in
            let result: Status
            do {
                try await MathModelDownload.run(entry, root: root, session: session, progress: progress)
                result = .installed
            } catch is CancellationError {
                result = .notInstalled
            } catch let e as URLError where e.code == .cancelled {
                result = .notInstalled
            } catch {
                result = .failed(String(describing: error))
            }
            guard let self else { return }
            self.downloads[entry.id] = nil
            self.status[entry.id] = result
        }
    }

    private func progressed(_ entry: MathModelCatalogEntry, done: Int64) {
        if case .downloading = status[entry.id] {
            status[entry.id] = .downloading(done: done, total: entry.downloadBytes)
        }
    }

    func cancelDownload(_ entry: MathModelCatalogEntry) {
        downloads[entry.id]?.cancel()
    }

    /// Deletes the installed copy of `entry`.
    func remove(_ entry: MathModelCatalogEntry) {
        if loaded?.id == entry.id { loaded = nil }
        try? MathModelStore.remove(id: entry.id, root: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".compiled/\(entry.manifestSHA256)"))
        refresh()
    }

    /// The recogniser of the first installed model, loaded (and compiled,
    /// once) off the main actor.
    func recognizer() async throws -> any MathRecognizing {
        if let recognizerOverride { return recognizerOverride }
        if let loaded { return loaded.recognizer }
        let root = self.root, catalog = self.catalog, local = localFolder
        let made: (String, any MathRecognizing) = try await Task.detached(priority: .userInitiated) {
            try Self.load(root: root, catalog: catalog, local: local)
        }.value
        loaded = made
        return made.1
    }

    enum Failure: Error, CustomStringConvertible {
        case noModel
        case unsupported
        var description: String {
            switch self {
            case .noModel: return String(localized: "No handwriting model is installed. Download one in Settings.",
                                         comment: "Convert to Math without a model")
            case .unsupported: return String(localized: "This device cannot run the handwriting model.",
                                             comment: "Convert to Math: Core ML unavailable")
            }
        }
    }

    nonisolated private static func load(root: URL, catalog: [MathModelCatalogEntry],
                                         local: URL?) throws -> (String, any MathRecognizing) {
        #if canImport(CoreML)
        if let local {
            let m = try MathModelStore.manifest(in: local)
            try MathModelStore.verify(m, in: local)
            return (m.id, try CoreMLMathRecognizer(folder: local, manifest: m))
        }
        for entry in catalog {
            guard let (folder, m) = MathModelStore.installed(entry, root: root) else { continue }
            let compiled = root.appendingPathComponent(".compiled", isDirectory: true).appendingPathComponent(entry.manifestSHA256)
            return (entry.id, try CoreMLMathRecognizer(folder: folder, manifest: m, compiledCache: compiled))
        }
        throw Failure.noModel
        #else
        throw Failure.unsupported
        #endif
    }
}

/// Fetches one URL to a local file (the app's only network use, and only
/// when the user asks for a model; tests use a fake).
protocol MathModelFetching: Sendable {
    /// Downloads `url` to a new temporary file and returns it; refuses more than `maxBytes`.
    func fetch(_ url: URL, maxBytes: Int64) async throws -> URL
}

struct URLSessionModelFetcher: MathModelFetching {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    func fetch(_ url: URL, maxBytes: Int64) async throws -> URL {
        guard url.scheme == "https" else { throw Failure(description: "not an HTTPS URL") }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: file)
            throw Failure(description: "the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else {
            try? FileManager.default.removeItem(at: file)
            throw Failure(description: "the file is larger than expected")
        }
        return file
    }
}

/// One model download, off the main actor: into a staging folder under the
/// store, checked file by file, then installed (`MathModelStore.install`).
enum MathModelDownload {
    static func run(_ entry: MathModelCatalogEntry, root: URL, session: MathModelFetching,
                    progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var backupFree = root
        try? backupFree.setResourceValues(values)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        guard let manifestURL = URL(string: entry.manifestURL), manifestURL.scheme == "https" else {
            throw MathModelManifest.Failure.malformed("the catalogue's manifest URL is not HTTPS")
        }
        let manifestFile = try await session.fetch(manifestURL, maxBytes: Int64(MathModelManifest.maxBytes))
        try fm.moveItem(at: manifestFile, to: staging.appendingPathComponent("manifest.json"))
        let manifest = try MathModelStore.manifest(in: staging, expectedSHA256: entry.manifestSHA256)
        var done: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard let url = entry.fileURL(file.path) else { throw MathModelManifest.Failure.malformed("bad path \(file.path)") }
            let fetched = try await session.fetch(url, maxBytes: file.size)
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: fetched, to: target)
            // Checked as it lands, so a wrong file stops the download early.
            let (hex, size) = try FileDigest.sha256(of: target, maxBytes: file.size)
            guard hex == file.sha256, size == file.size else { throw MathModelManifest.Failure.mismatch(file.path) }
            done += file.size
            progress(done)
        }
        try Task.checkCancellation()
        try MathModelStore.install(from: staging, manifestSHA256: entry.manifestSHA256, root: root)
    }
}
