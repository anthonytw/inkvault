import Age
import Foundation

/// The result of `Vault.verify()`.
public struct VerifyReport: Hashable, Sendable {
    /// Per-file outcome.
    public enum Status: String, Hashable, Sendable, CaseIterable {
        /// Decrypted, tag verified, decoded, encrypted to the current
        /// recipient count. For `keys/` files: a well-named identity file
        /// (not decrypted; that needs its passphrase).
        case ok
        /// The inner tag does not match (format.md §4).
        case tagMismatch
        /// age decryption failed, or the file could not be read.
        case undecryptable
        /// Not a valid framed gzip body.
        case corruptBody
        /// The JSON is not a revision of this note under this name.
        case undecodable
        /// Readable and verified, but encrypted to a different number of
        /// recipients than `vault.json` lists: an unfinished recipient change.
        case staleRecipients
        /// Not part of the format; ignored, never deleted.
        case unknownFile
        /// The vault is locked, so the file was not decrypted.
        case notChecked
    }

    /// One file or directory.
    public struct FileResult: Hashable, Sendable {
        /// Path relative to the vault directory, `/`-separated.
        public var path: String
        public var status: Status
        /// Human-readable detail for anything not `ok`.
        public var detail: String?
    }

    /// Problems found in `vault.json`; empty when it is fine.
    public var manifestProblems: [String] = []
    /// Every entry examined, in walk order.
    public var files: [FileResult] = []
    /// True while a recipient change is unfinished.
    public var rewrapPending = false

    /// True when `vault.json` passed every check.
    public var manifestOK: Bool { manifestProblems.isEmpty }

    /// Number of entries per status.
    public var counts: [Status: Int] {
        files.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    /// True when the manifest is fine and every file is `ok`, `unknownFile`
    /// or (locked vault) `notChecked`.
    public var isHealthy: Bool {
        manifestOK && files.allSatisfy { [.ok, .unknownFile, .notChecked].contains($0.status) }
    }
}

extension VerifyReport.Status {
    init(_ e: RevisionReadError) {
        switch e {
        case .locked: self = .notChecked
        case .unreadable, .undecryptable: self = .undecryptable
        case .tagMismatch: self = .tagMismatch
        case .corruptBody: self = .corruptBody
        case .undecodable: self = .undecodable
        }
    }
}

extension Vault {
    /// Walks the whole vault: re-reads and checks `vault.json`, then reads
    /// and verifies every revision file. Never throws; one bad file is one
    /// line of the report.
    public func verify() -> VerifyReport {
        var report = VerifyReport()
        report.rewrapPending = pendingRewrap
        report.manifestProblems = manifestProblems()

        for entry in FileIO.entries(url) where ![Self.manifestName, Self.keysName, Self.notesName,
                                                 Self.journalName].contains(entry) {
            report.files.append(.init(path: entry, status: .unknownFile, detail: nil))
        }
        for entry in FileIO.entries(keysURL) {
            let ok = IdentityFile.recipient(fromFileName: entry) != nil
                && !FileIO.isDirectory(keysURL.appendingPathComponent(entry))
            report.files.append(.init(path: "\(Self.keysName)/\(entry)", status: ok ? .ok : .unknownFile,
                                      detail: nil))
        }
        let recipientCount = manifest.recipients.count
        for note in FileIO.entries(notesURL) {
            let dir = notesURL.appendingPathComponent(note)
            let base = "\(Self.notesName)/\(note)"
            guard Self.isNoteDirectoryName(note), FileIO.isDirectory(dir) else {
                report.files.append(.init(path: base, status: .unknownFile, detail: nil))
                continue
            }
            for entry in FileIO.entries(dir) {
                let path = "\(base)/\(entry)"
                let file = dir.appendingPathComponent(entry)
                guard let name = RevisionName(entry), name.filename == entry, !FileIO.isDirectory(file) else {
                    report.files.append(.init(path: path, status: .unknownFile, detail: nil))
                    continue
                }
                guard let secret else {
                    report.files.append(.init(path: path, status: .notChecked, detail: "vault locked"))
                    continue
                }
                do {
                    let data = try FileIO.read(file)
                    _ = try decodeRevisionFile(data, note: note, name: name, secret: secret)
                    let stanzas = (try? AgeFile.parseHeader(data).header.stanzas.count) ?? 0
                    if stanzas != recipientCount {
                        report.files.append(.init(path: path, status: .staleRecipients,
                                                  detail: "\(stanzas) stanzas, \(recipientCount) recipients"))
                    } else {
                        report.files.append(.init(path: path, status: .ok, detail: nil))
                    }
                } catch let e as RevisionReadError {
                    report.files.append(.init(path: path, status: .init(e), detail: "\(e)"))
                } catch {
                    report.files.append(.init(path: path, status: .undecryptable, detail: "\(error)"))
                }
            }
        }
        return report
    }

    func manifestProblems() -> [String] {
        let data: Data
        do { data = try FileIO.read(manifestURL) } catch { return ["vault.json: \(error)"] }
        let m: VaultManifest
        do { m = try Self.readManifest(data) } catch { return ["vault.json: \(error)"] }
        var problems: [String] = []
        if m != manifest { problems.append("vault.json changed on disk since the vault was opened") }
        let armored = Data(m.vaultSecret.utf8)
        // Count stanzas: the secret must be encrypted to exactly the recipients.
        if let stanzas = try? AgeFile.parseHeader(binaryAge(armored)).header.stanzas.count,
           stanzas != m.recipients.count {
            problems.append("vaultSecret has \(stanzas) stanzas for \(m.recipients.count) recipients")
        }
        if !identities.isEmpty {
            do {
                let s = try Self.decryptSecret(m.vaultSecret, with: identities)
                if let secret, s != secret { problems.append("vaultSecret differs from the one in use") }
            } catch {
                problems.append("vaultSecret: \(error)")
            }
        }
        return problems
    }

    /// The binary form of an armored age file (for header inspection).
    func binaryAge(_ armored: Data) -> Data {
        let text = String(decoding: armored, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined()) ?? Data()
    }
}
