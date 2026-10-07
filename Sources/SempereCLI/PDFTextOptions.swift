import ArgumentParser
import Foundation
import Sempere
import SemperePDF
import SempereRender

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// How PDF pages get their `pageText` (format.md §8.2.6) in commands that add PDF pages.
enum PDFTextMode: String, ExpressibleByArgument, CaseIterable {
    /// Poppler's `pdftotext` when installed, else the built-in reader.
    case auto
    /// The built-in pure-Swift reader (`SemperePDF.PDFText`).
    case builtin
    /// Poppler's `pdftotext` (an error when it is not installed).
    case poppler
    /// No text.
    case none
}

struct PDFTextOptions: ParsableArguments {
    @Option(name: .customLong("pdf-text"),
            help: ArgumentHelp("Store each PDF page's text for search: auto (pdftotext if installed, else built in), builtin, poppler or none.",
                               valueName: "mode"))
    var mode: PDFTextMode = .auto

    /// The extractor for `mode`; nil for `none`.
    ///
    /// - Throws: `CLIError` for `poppler` without `pdftotext`.
    func extractor(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (any PDFTextExtracting)? {
        switch mode {
        case .none: return nil
        case .builtin: return BuiltinPDFTextExtractor()
        case .poppler:
            guard let p = PopplerTextExtractor.locate(environment: environment) else {
                throw CLIError.failure("--pdf-text poppler: pdftotext is not installed (or SEMPERE_PDFTOTEXT is not executable)")
            }
            return PopplerTextExtractor(executable: p)
        case .auto:
            return PopplerTextExtractor.locate(environment: environment).map { PopplerTextExtractor(executable: $0) }
                ?? BuiltinPDFTextExtractor()
        }
    }
}

/// Poppler's `pdftotext`, run like `PopplerRasterizer` runs `pdftoppm`: an
/// argument vector (no shell) through the `__exec-limited` trampoline
/// (CPU, memory and output size limits), a wall-clock timeout, output in a
/// private temporary directory read back with a size bound. One run reads
/// every page; pages are split at the form feeds `pdftotext` ends each page with.
struct PopplerTextExtractor: PDFTextExtracting {
    let executable: String
    var timeout = 120.0
    var memoryLimit = 3 << 30
    /// Largest text file read back (a page's text is cut at 64 KiB when stored).
    var maxOutputBytes = 256 << 20

    var engine: String { "pdftotext" + (Self.version(executable).map { "-" + $0 } ?? "") }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// `SEMPERE_PDFTOTEXT`, else `pdftotext` on `PATH`.
    static func locate(environment: [String: String]) -> String? {
        if let p = environment["SEMPERE_PDFTOTEXT"] {
            return !p.isEmpty && FileManager.default.isExecutableFile(atPath: p) ? p : nil
        }
        for dir in (environment["PATH"] ?? "/usr/bin:/usr/local/bin").split(separator: ":") {
            let p = "\(dir)/pdftotext"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// `pdftotext -v` prints `pdftotext version 24.02.0` on standard error.
    static func version(_ executable: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-v"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile().prefix(4096)
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "version ") else { return nil }
        let v = text[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return v.isEmpty ? nil : String(v)
    }

    func pageTexts(_ data: Data, pages: [Int]) throws -> [Int: String] {
        guard let first = pages.min(), let last = pages.max(), first >= 0, last < Int(Int32.max) else { return [:] }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sempere-pdftotext-\(UUID().uuidString.lowercased())")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { throw Failure(message: "cannot create a temporary directory") }
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.pdf"), output = dir.appendingPathComponent("out.txt")
        guard fm.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "cannot write a temporary file")
        }
        let args = ["-enc", "UTF-8", "-f", String(first + 1), "-l", String(last + 1), "--", input.path, output.path]
        let p = Process()
        if let me = Bundle.main.executablePath {
            p.executableURL = URL(fileURLWithPath: me)
            p.arguments = [ExecLimited.command, "--cpu", String(Int(timeout.rounded(.up)) + 1),
                           "--memory", String(memoryLimit), "--file-size", String(maxOutputBytes),
                           "--", executable] + args
        } else {
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
        }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw Failure(message: "cannot run \(executable): \(error.localizedDescription)") }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 5)
            }
            throw Failure(message: "pdftotext timed out after \(Int(timeout)) s")
        }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            throw Failure(message: "pdftotext failed (status \(p.terminationStatus))")
        }
        let text: Data
        do { text = try BoundedRead.contents(of: output, maxBytes: maxOutputBytes) } catch {
            throw Failure(message: "pdftotext wrote no usable text")
        }
        return Self.split(String(decoding: text, as: UTF8.self), first: first, wanted: Set(pages))
    }

    /// Pages of `pdftotext` output (each ends with a form feed) from page `first`.
    static func split(_ text: String, first: Int, wanted: Set<Int>) -> [Int: String] {
        var out: [Int: String] = [:]
        var parts = text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
        if parts.last?.allSatisfy(\.isWhitespace) == true { parts.removeLast() }
        for (k, part) in parts.enumerated() where wanted.contains(first + k) { out[first + k] = String(part) }
        return out
    }
}
