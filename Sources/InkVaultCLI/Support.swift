import Age
import ArgumentParser
import Foundation
import InkVault

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Errors and exit codes

/// A failure with its exit code. The message is one line.
struct CLIError: Error {
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let unhealthy: Int32 = 3
    static let cannotDecrypt: Int32 = 4

    var message: String
    var code: Int32

    init(_ message: String, code: Int32 = CLIError.failure) {
        self.message = message
        self.code = code
    }

    /// Maps a library error to a message and an exit code.
    static func from(_ error: Error) -> CLIError {
        if let e = error as? CLIError { return e }
        func one(_ s: String) -> String {
            s.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        switch error {
        case AgeError.noMatchingIdentity:
            return CLIError("cannot decrypt: none of the given keys matches", code: cannotDecrypt)
        case AgeError.noIdentities:
            return CLIError("cannot decrypt: no identity given", code: cannotDecrypt)
        case VaultError.vaultSecretUndecryptable:
            return CLIError("cannot decrypt the vault: wrong key", code: cannotDecrypt)
        case VaultError.wrongPassphrase:
            return CLIError("cannot decrypt the key file: wrong passphrase", code: cannotDecrypt)
        case VaultError.rewrapIncomplete(let files):
            return CLIError("recipient change incomplete (\(files.count) file(s)); "
                + "run `inkvault vault rewrap-resume`", code: unhealthy)
        case let VaultError.revision(name, inner):
            return CLIError("\(name): \(one("\(inner)"))")
        case VaultError.locked, VaultError.noIdentities:
            return CLIError("the vault is locked: give --identity FILE", code: cannotDecrypt)
        case let e as VaultError:
            return CLIError(one("\(e)"))
        case let e as NoteSummary.LookupError:
            switch e {
            case .notFound(let q): return CLIError("no note matches '\(q)'")
            case .ambiguous(let q, let ids):
                return CLIError("'\(q)' is ambiguous: \(ids.map { $0.uuidString.lowercased() }.joined(separator: ", "))")
            }
        case let e as LocalizedError where e.errorDescription != nil:
            return CLIError(one(e.errorDescription ?? ""))
        default:
            return CLIError(one("\(error)"))
        }
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("inkvault: " + message + "\n").utf8))
}

func printStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Shared options

/// `--json`, `-q`, `-v`.
struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable JSON output.")
    var json = false

    @Flag(name: .shortAndLong, help: "Print only what was asked for (and errors).")
    var quiet = false

    @Flag(name: .shortAndLong, help: "Print extra detail.")
    var verbose = false

    /// Prints an informational line unless `-q`.
    func info(_ text: @autoclosure () -> String) {
        if !quiet && !json { print(text()) }
    }

    func emitJSON<T: Encodable>(_ value: T) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Format.utc(date))
        }
        print(String(decoding: try enc.encode(value), as: UTF8.self))
    }
}

/// `--vault`, `--identity`, `--passphrase-env`.
struct AccessOptions: ParsableArguments {
    @Option(name: .long, help: ArgumentHelp("The vault directory (*.inkvault).", discussion: "Default: $INKVAULT_VAULT.",
                                            valueName: "path"))
    var vault: String?

    @Option(name: .long, help: ArgumentHelp("An age identity file (age-keygen style). Repeatable.",
                                            discussion: "Default: $INKVAULT_IDENTITY.", valueName: "file"))
    var identity: [String] = []

    @Option(name: .customLong("passphrase-env"),
            help: ArgumentHelp("Name of the environment variable holding the passphrase of the vault's key file.",
                               discussion: "Without it $INKVAULT_PASSPHRASE is used, else the terminal is asked.",
                               valueName: "var"))
    var passphraseEnv: String?
}

// MARK: - Formatting

enum Format {
    static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Local time with an explicit offset, for people.
    static func local(_ date: Date?) -> String {
        guard let date else { return "-" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    /// Left-aligned columns separated by two spaces; the last column is not padded.
    static func table(_ rows: [[String]]) -> String {
        guard let first = rows.first else { return "" }
        var widths = [Int](repeating: 0, count: first.count)
        for r in rows { for (i, c) in r.enumerated() { widths[i] = max(widths[i], c.count) } }
        return rows.map { r in
            r.enumerated().map { i, c in
                i == r.count - 1 ? c : c.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

// MARK: - Files

/// Creates `path` with mode 0600, refusing to overwrite.
func writeNewSecretFile(_ text: String, to path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if fd < 0 {
        if errno == EEXIST { throw CLIError("refusing to overwrite \(path)") }
        throw CLIError("cannot create \(path): \(String(cString: strerror(errno)))")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    handle.write(Data(text.utf8))
}

func readIdentityFile(_ path: String) throws -> X25519Identity {
    let text: String
    do { text = try String(contentsOfFile: path, encoding: .utf8) } catch {
        throw CLIError("cannot read \(path): \(error.localizedDescription)")
    }
    do { return try IdentityFile.parse(text) } catch {
        throw CLIError("\(path) holds no AGE-SECRET-KEY identity")
    }
}

// MARK: - Passphrase and vault access

enum Env {
    static var vars: [String: String] { ProcessInfo.processInfo.environment }
}

/// Reads a line from the terminal with echo off; nil when stdin is not a terminal.
func promptSecret(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) == 1 else { return nil }
    var old = termios()
    guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
    var raw = old
    raw.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    defer {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &old)
        FileHandle.standardError.write(Data("\n".utf8))
    }
    FileHandle.standardError.write(Data(prompt.utf8))
    return readLine()
}

/// Whether a passphrase can be had without asking a person.
func passphraseAvailableWithoutPrompt(envName: String?) -> Bool {
    if let envName { return Env.vars[envName] != nil }
    return Env.vars["INKVAULT_PASSPHRASE"] != nil
}

/// `--passphrase-env VAR`, else `$INKVAULT_PASSPHRASE`, else the terminal.
func obtainPassphrase(envName: String?, prompt: String = "Vault passphrase: ", confirm: Bool = false) throws -> String {
    if let envName {
        guard let v = Env.vars[envName] else { throw CLIError("environment variable \(envName) is not set") }
        return v
    }
    if let v = Env.vars["INKVAULT_PASSPHRASE"] { return v }
    guard let first = promptSecret(prompt) else {
        throw CLIError("no passphrase: set INKVAULT_PASSPHRASE or --passphrase-env VAR (stdin is not a terminal)")
    }
    if confirm {
        guard promptSecret("Repeat passphrase: ") == first else { throw CLIError("passphrases differ") }
    }
    return first
}

/// How much unlocking a command needs.
enum Unlock {
    /// The vault must be readable.
    case required
    /// Unlock only without asking anyone (identities or a scripted passphrase).
    case ifPossible
}

extension AccessOptions {
    func vaultURL() throws -> URL {
        guard let path = vault ?? Env.vars["INKVAULT_VAULT"], !path.isEmpty else {
            throw CLIError("no vault: pass --vault PATH or set INKVAULT_VAULT", code: CLIError.usage)
        }
        return URL(fileURLWithPath: path)
    }

    /// `--identity` files plus `$INKVAULT_IDENTITY`.
    func explicitIdentities() throws -> [X25519Identity] {
        var paths = identity
        if paths.isEmpty, let env = Env.vars["INKVAULT_IDENTITY"], !env.isEmpty { paths = [env] }
        return try paths.map(readIdentityFile)
    }

    /// The identity stored passphrase-wrapped in the vault's `keys/`.
    func identityFromKeyFiles(of locked: Vault, recipient: X25519Recipient? = nil) throws -> X25519Identity {
        let files = try locked.identityFiles()
        let candidates: [X25519Recipient]
        if let recipient {
            candidates = [recipient]
        } else {
            candidates = files
        }
        guard !candidates.isEmpty else {
            throw CLIError("no identity: pass --identity FILE (the vault stores no passphrase-wrapped key)",
                           code: CLIError.cannotDecrypt)
        }
        let pass = try obtainPassphrase(envName: passphraseEnv)
        var lastError: Error = VaultError.wrongPassphrase
        for r in candidates {
            do { return try locked.readIdentityFile(recipient: r, passphrase: pass) } catch { lastError = error }
        }
        throw lastError
    }

    /// Opens the vault with the identities this invocation provides.
    func openVault(_ unlock: Unlock) throws -> Vault {
        let url = try vaultURL()
        var ids: [any AgeIdentity] = try explicitIdentities()
        if ids.isEmpty {
            let locked = try Vault.open(at: url)
            switch unlock {
            case .ifPossible:
                guard passphraseAvailableWithoutPrompt(envName: passphraseEnv),
                      !((try? locked.identityFiles()) ?? []).isEmpty else { return locked }
                ids = [try identityFromKeyFiles(of: locked)]
            case .required:
                ids = [try identityFromKeyFiles(of: locked)]
            }
        }
        return try Vault.open(at: url, identities: ids)
    }
}

extension AccessOptions {
    /// For commands that take only some of the access options (`recover`).
    static func make(identity: [String], passphraseEnv: String?) -> AccessOptions {
        var a = AccessOptions()
        a.identity = identity
        a.passphraseEnv = passphraseEnv
        return a
    }
}
