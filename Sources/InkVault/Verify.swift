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
        /// A directory that exists but could not be listed; its contents are
        /// unknown, so the vault is not healthy.
        case unlistable
        /// The vault cannot read (locked, or no identities), so the file was
        /// not decrypted.
        case notChecked
    }

    /// One file or directory.
    public struct FileResult: Hashable, Sendable {
        /// Path relative to the vault directory, `/`-separated.
        public var path: String
        /// What was found: `ok`, a failure stage, or why it was not checked.
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
    /// Why the pending rewrap journal could not be read, if it could not.
    public var journalProblem: String?

    /// True when `vault.json` passed every check.
    public var manifestOK: Bool { manifestProblems.isEmpty }

    /// Number of entries per status.
    public var counts: [Status: Int] {
        files.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    /// True when the manifest and any pending journal are fine and every
    /// entry is `ok`, `unknownFile` or (vault that cannot read) `notChecked`.
    public var isHealthy: Bool {
        manifestOK && journalProblem == nil
            && files.allSatisfy { [.ok, .unknownFile, .notChecked].contains($0.status) }
    }
}

extension VerifyReport.Status {
    init(_ e: RevisionReadError) {
        switch e {
        case .unreadable, .undecryptable: self = .undecryptable
        case .tagMismatch, .tagMismatchJournalUnreadable: self = .tagMismatch
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
        report.journalProblem = pendingRewrap ? journalProblem : nil
        report.manifestProblems = manifestProblems()

        /// Lists `dir`, recording an `unlistable` entry instead of throwing.
        func list(_ dir: URL, as path: String) -> [String] {
            do { return try FileIO.entries(dir) } catch {
                report.files.append(.init(path: path, status: .unlistable, detail: "\(error)"))
                return []
            }
        }

        for entry in list(url, as: ".") where ![Self.manifestName, Self.keysName, Self.notesName,
                                                Self.journalName].contains(entry) {
            report.files.append(.init(path: entry, status: .unknownFile, detail: nil))
        }
        for entry in list(keysURL, as: Self.keysName) {
            let ok = IdentityFile.isKeyFileName(entry)
                && !FileIO.isDirectory(keysURL.appendingPathComponent(entry))
            report.files.append(.init(path: "\(Self.keysName)/\(entry)", status: ok ? .ok : .unknownFile,
                                      detail: nil))
        }
        let expected = Self.expectedStanzas((try? ageRecipients()) ?? [])
        let notReadable = secret == nil ? "vault locked" : identities.isEmpty ? "no identities" : nil
        for note in list(notesURL, as: Self.notesName) {
            let dir = notesURL.appendingPathComponent(note)
            let base = "\(Self.notesName)/\(note)"
            guard Self.isNoteDirectoryName(note), FileIO.isDirectory(dir) else {
                report.files.append(.init(path: base, status: .unknownFile, detail: nil))
                continue
            }
            for entry in list(dir, as: base) {
                let path = "\(base)/\(entry)"
                let file = dir.appendingPathComponent(entry)
                guard let name = RevisionName(entry), name.filename == entry, !FileIO.isDirectory(file) else {
                    report.files.append(.init(path: path, status: .unknownFile, detail: nil))
                    continue
                }
                guard let secret, notReadable == nil else {
                    report.files.append(.init(path: path, status: .notChecked, detail: notReadable))
                    continue
                }
                do {
                    let data = try FileIO.read(file)
                    _ = try decodeRevisionFile(data, note: note, name: name, secret: secret)
                    let stanzas = (try? Self.stanzaCounts(data)) ?? [:]
                    if stanzas != expected {
                        report.files.append(.init(path: path, status: .staleRecipients,
                                                  detail: "stanzas: \(Self.describe(stanzas)); recipients need: "
                                                      + Self.describe(expected)))
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
        // The secret must be armored age encrypted to exactly the recipients.
        do {
            let binary = try Armor.decode(Data(m.vaultSecret.utf8))
            let stanzas = try Self.stanzaCounts(binary)
            let expected = Self.expectedStanzas(try m.recipients.map { try NativeRecipient(string: $0.key) })
            if stanzas != expected {
                problems.append("vaultSecret has stanzas \(Self.describe(stanzas)) for recipients needing "
                    + Self.describe(expected))
            }
        } catch {
            problems.append("vaultSecret is not an armored age file: \(error)")
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
}
