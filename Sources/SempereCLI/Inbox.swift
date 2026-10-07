import ArgumentParser
import Foundation
import Sempere

/// `sempere inbox`: quick capture without unlocking (format.md §11,
/// docs/quick-capture.md). `enable` stores a capture profile for this
/// machine (needs the key once); `capture` and `transcript` seal into the
/// vault's inbox with that profile alone; `import` adopts what the inbox
/// holds as notes (needs the key); `list` shows it.
struct InboxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Capture voice notes without the key, and adopt them as notes.",
        subcommands: [InboxEnable.self, InboxCapture.self, InboxTranscript.self, InboxList.self, InboxImport.self]
    )
}

/// `--profile`: where this machine keeps a vault's capture profile.
struct ProfileOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The capture profile file (default: $XDG_STATE_HOME/sempere/capture/<vault id>.json).",
                                            valueName: "path"))
    var profile: String?

    func url(vaultId: UUID) -> URL {
        if let profile { return URL(fileURLWithPath: profile) }
        return DeviceState.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("capture/\(vaultId.uuidString.lowercased()).json")
    }

    func load(vaultId: UUID) throws -> CaptureProfile {
        let url = url(vaultId: vaultId)
        let data: Data
        do { data = try BoundedRead.contents(of: url, maxBytes: 1 << 20) } catch {
            throw CLIError.failure("no capture profile for this vault at \(url.path): run `sempere inbox enable` once (it needs the key)")
        }
        let p: CaptureProfile
        do { p = try JSONDecoder().decode(CaptureProfile.self, from: data) } catch {
            throw CLIError.failure("\(url.path) is not a capture profile")
        }
        guard p.vaultId == vaultId else { throw CLIError.failure("\(url.path) is the capture profile of another vault") }
        return p
    }
}

struct InboxEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Store this machine's capture profile for the vault (needs the key once).",
        discussion: """
            The profile holds the vault's public recipients and its capture key (derived from the vault secret; \
            it can only put captures in the inbox, never read or change notes). It is written with mode 0600. \
            Run it again after the vault's keys change (a removed key rotates the capture key).
            """
    )

    @Option(name: .long, help: ArgumentHelp("The notebook captures are adopted into.", valueName: "name"))
    var notebook: String = CaptureProfile.defaultNotebook

    @OptionGroup var profile: ProfileOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let device = try DeviceState.loadOrCreate(at: DeviceState.defaultURL()).device
        let p = try vault.captureProfile(device: device, notebook: notebook)
        let url = profile.url(vaultId: vault.vaultId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: try enc.encode(p), attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        if output.json {
            struct Out: Encodable { var profile: String; var device: String; var notebook: String }
            try output.emitJSON(Out(profile: url.path, device: p.device, notebook: p.notebook))
        } else {
            output.info("Capture profile written to \(url.path) (notebook \(p.notebook))")
        }
    }
}

struct InboxCapture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Put an audio file in the vault's inbox, encrypted, without the key.",
        discussion: """
            Seals the file with the capture profile (no key, no passphrase) as inbox/<id>.capture.age: encrypted \
            to the vault's recipients and tagged with the capture key. The next `sempere inbox import`, or the \
            app once the vault is unlocked, makes it a note in the inbox notebook titled from the date. Prints \
            the capture id. --transcript seals a transcript (sempere-transcript/1 JSON; its recording id is \
            replaced by the capture's) next to it.
            """
    )

    @Argument(help: ArgumentHelp("An audio file (.m4a).", valueName: "file"))
    var file: String

    @Option(name: .long, help: ArgumentHelp("The note's title (default: Voice note <date> <time>).", valueName: "title"))
    var title: String?

    @Option(name: .long, help: ArgumentHelp("When the first sample was recorded (RFC 3339).", valueName: "time"))
    var started: String?

    @Option(name: .long, help: ArgumentHelp("Media type of the audio.", valueName: "type"))
    var type: String = "audio/mp4"

    @Option(name: .long, help: ArgumentHelp("A transcript JSON file to seal with it.", valueName: "file"))
    var transcript: String?

    @OptionGroup var profile: ProfileOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let started, RFC3339.parse(started) == nil { throw ValidationError("--started is not an RFC 3339 time: \(started)") }
        if !type.lowercased().hasPrefix("audio/") { throw ValidationError("--type must be an audio/… media type") }
    }

    func run() throws {
        // The vault is opened locked: only vault.json is read.
        let vault = try Vault.open(at: try access.vaultURL())
        let writer = try CaptureWriter(profile: try profile.load(vaultId: vault.vaultId))
        let url = URL(fileURLWithPath: file)
        let audio: Data
        do { audio = try BoundedRead.contents(of: url, maxBytes: CaptureFile.maxBytes - (1 << 20)) } catch {
            throw CLIError.failure("cannot read \(file): \(CLIError.from(error).message)")
        }
        let info = try? AudioProbe.probe(audio)
        let when: Date
        if let started, let t = RFC3339.parse(started) {
            when = t
        } else {
            let end = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? Date()
            when = end.addingTimeInterval(-(info?.duration ?? 0))
        }
        let id = UUID()
        var sealed = [try writer.seal(audio: audio, type: type, started: when, info: info, title: title, id: id)]
        if let transcript {
            let data: Data
            do { data = try BoundedRead.contents(of: URL(fileURLWithPath: transcript), maxBytes: Transcript.maxSize) } catch {
                throw CLIError.failure("cannot read \(transcript): \(CLIError.from(error).message)")
            }
            var t: Transcript
            do { t = try Transcript.decode(data) } catch { throw CLIError.failure("\(transcript): invalid transcript: \(error)") }
            t.recording = CaptureAdoption.ids(for: id).recording
            sealed.append(try writer.seal(transcript: t, capture: id))
        }
        for s in sealed { try CaptureWriter.store(s, in: vault.inboxURL) }
        let ids = CaptureAdoption.ids(for: id)
        if output.json {
            struct Out: Encodable { var capture: String; var note: String; var files: [String] }
            try output.emitJSON(Out(capture: id.uuidString.lowercased(), note: ids.note.uuidString.lowercased(),
                                    files: sealed.map { "\(CaptureFile.folderName)/\($0.name)" }))
        } else {
            print(id.uuidString.lowercased())
            if !output.quiet { printStderr("Captured into \(CaptureFile.folderName)/ (adopted as note \(ids.note.uuidString.lowercased().prefix(8)) on the next import)") }
        }
    }
}

struct InboxTranscript: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Seal a transcript for a capture, without the key.",
        discussion: """
            For a transcript made after the capture (the app's background transcription does the same). Its \
            recording id is replaced by the capture's. It is added to the capture's recording when adopted, \
            also if the capture itself was adopted earlier.
            """
    )

    @Argument(help: ArgumentHelp("The capture id.", valueName: "capture"))
    var capture: String

    @Argument(help: ArgumentHelp("A sempere-transcript/1 JSON file.", valueName: "file"))
    var file: String

    @OptionGroup var profile: ProfileOptions
    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let id = UUID(uuidString: capture) else { throw CLIError.usage("not a capture id: \(capture)") }
        let vault = try Vault.open(at: try access.vaultURL())
        let writer = try CaptureWriter(profile: try profile.load(vaultId: vault.vaultId))
        let data: Data
        do { data = try BoundedRead.contents(of: URL(fileURLWithPath: file), maxBytes: Transcript.maxSize) } catch {
            throw CLIError.failure("cannot read \(file): \(CLIError.from(error).message)")
        }
        var t: Transcript
        do { t = try Transcript.decode(data) } catch { throw CLIError.failure("\(file): invalid transcript: \(error)") }
        t.recording = CaptureAdoption.ids(for: id).recording
        let sealed = try writer.seal(transcript: t, capture: id)
        try CaptureWriter.store(sealed, in: vault.inboxURL)
        if output.json {
            struct Out: Encodable { var capture: String; var file: String }
            try output.emitJSON(Out(capture: id.uuidString.lowercased(), file: "\(CaptureFile.folderName)/\(sealed.name)"))
        } else {
            output.info("Sealed \(CaptureFile.folderName)/\(sealed.name)")
        }
    }
}

struct InboxList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the captures waiting in the inbox.",
        discussion: "Without a key only ids and file kinds are shown; with one, titles and whether each verifies."
    )

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    struct Entry: Encodable {
        var capture: String
        var kinds: [String]
        var title: String?
        var started: Date?
        var duration: Double?
        var error: String?
    }

    func run() throws {
        let vault = try access.openVault(.ifPossible)
        let entries: [Entry] = try vault.inboxEntries().map { e in
            var out = Entry(capture: e.id.uuidString.lowercased(), kinds: e.kinds.map(\.rawValue).sorted())
            if vault.canRead {
                do {
                    let p = try vault.readCapture(e.id)
                    out.title = p.manifest?.title
                    out.started = p.manifest?.started
                    out.duration = p.manifest?.duration
                } catch {
                    out.error = (error as? CaptureError)?.description ?? CLIError.from(error).message
                }
            }
            return out
        }
        if output.json { try output.emitJSON(entries); return }
        for e in entries {
            var line = "\(e.capture)  \(e.kinds.joined(separator: "+"))"
            if let t = e.title { line += "  \(t)" }
            if let d = e.duration { line += "  \(Transcript.clock(d))" }
            if let err = e.error { line += "  (\(err))" }
            print(line)
        }
        output.info("\(entries.count) capture(s) in the inbox.")
    }
}

struct InboxImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Adopt the inbox's captures as notes (needs the key).",
        discussion: """
            Each capture is decrypted and verified (its tag under the vault's capture key, its audio's hash), \
            its audio and transcript written as blobs of a new note in the capture's notebook, then one delta, \
            then its inbox files are deleted. Note, page and recording ids come from the capture id, so two \
            machines importing the same capture write the same note. A transcript whose capture is not there \
            yet waits. A capture that does not verify is reported and kept.
            """
    )

    @Argument(help: ArgumentHelp("Capture ids (default: all).", valueName: "capture"))
    var captures: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Verify and list; write and delete nothing.")
    var dryRun = false

    @OptionGroup var access: AccessOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let vault = try access.openVault(.required)
        let ids: [UUID]
        if captures.isEmpty {
            ids = try vault.inboxEntries().map(\.id)
        } else {
            ids = try captures.map { s in
                guard let id = UUID(uuidString: s) else { throw CLIError.usage("not a capture id: \(s)") }
                return id
            }
        }
        let results = ids.map { vault.adoptCapture($0, deviceState: DeviceState.defaultURL(), app: appName, dryRun: dryRun) }
        if output.json {
            struct Out: Encodable { var dryRun: Bool; var captures: [Vault.CaptureAdoptionResult] }
            try output.emitJSON(Out(dryRun: dryRun, captures: results))
        } else {
            for r in results {
                let title = r.title ?? "(transcript)"
                if let e = r.error {
                    printStderr("failed \(r.capture.prefix(8)): \(e)")
                } else if dryRun {
                    output.info("\(r.capture.prefix(8)) \(title): would \(r.created ? "create" : "update") note \(r.note.prefix(8))")
                } else {
                    output.info("\(r.capture.prefix(8)) \(title): note \(r.note.prefix(8))\(r.created ? " created" : "")"
                                + "\(r.transcript ? ", transcript" : "")")
                }
            }
            output.info("\(dryRun ? "Dry run: " : "")\(results.filter { $0.error == nil }.count) of \(results.count) capture(s) \(dryRun ? "verified" : "adopted").")
        }
        let failed = results.filter { $0.error != nil }.count
        if failed > 0 { throw CLIError.failure("\(failed) capture(s) could not be adopted") }
    }
}
