import Foundation
import XCTest

@testable import Age

/// Interop with the reference `age` / `age-keygen` CLI (skipped when they
/// are not on PATH).
///
/// Passphrase interop is one-directional here: `age -p` and `age -d` read
/// passphrases only from a terminal, so they cannot be scripted. Reference
/// scrypt output is covered by the CCTV `scrypt*` vectors (decrypt
/// direction); our scrypt output is covered by our own round trips.
final class InteropTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("age-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    static func which(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var dirs: [String] = path.split(separator: ":").map { String($0) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    func tools() throws -> (age: URL, keygen: URL) {
        guard let age = Self.which("age"), let keygen = Self.which("age-keygen") else {
            throw XCTSkip("age / age-keygen not on PATH")
        }
        return (age, keygen)
    }

    @discardableResult
    func run(_ exe: URL, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        // stderr from age is small; stdout is drained first so a large
        // plaintext cannot fill the pipe and stall the child.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(
            p.terminationStatus, 0,
            "\(exe.lastPathComponent) \(args.joined(separator: " ")): \(String(decoding: err, as: UTF8.self))")
        return out
    }

    func random(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    func testX25519BothDirections() throws {
        let (age, keygen) = try tools()
        let keyFile = tmp.appendingPathComponent("key.txt")
        try run(keygen, ["-o", keyFile.path])
        let keyText = try String(contentsOf: keyFile, encoding: .utf8)
        let secret = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("AGE-SECRET-KEY-1") })
        let publicLine = try XCTUnwrap(keyText.split(separator: "\n").first { $0.hasPrefix("# public key: ") })
        let identity = try X25519Identity(string: String(secret))
        XCTAssertEqual(identity.string, String(secret))
        XCTAssertEqual(identity.recipient.string, String(publicLine.dropFirst("# public key: ".count)))
        // age-keygen -y agrees on the recipient.
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), identity.recipient.string)

        for size in [0, 1, 65_536, 65_537, 200_000] {
            let plaintext = random(size)
            for armor in [false, true] {
                // Ours -> age -d.
                let ct = try Age.encrypt(plaintext, to: [identity.recipient], armor: armor)
                let ctFile = tmp.appendingPathComponent("ours-\(size)-\(armor).age")
                try ct.write(to: ctFile)
                XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ctFile.path]), plaintext, "ours->age \(size) \(armor)")

                // age -r -> ours.
                let ptFile = tmp.appendingPathComponent("pt-\(size)")
                try plaintext.write(to: ptFile)
                let outFile = tmp.appendingPathComponent("theirs-\(size)-\(armor).age")
                try run(age, ["-r", identity.recipient.string] + (armor ? ["-a"] : []) + ["-o", outFile.path, ptFile.path])
                let theirs = try Data(contentsOf: outFile)
                XCTAssertEqual(try Age.decrypt(theirs, with: [identity]), plaintext, "age->ours \(size) \(armor)")
            }
        }
    }

    func testOurKeysWorkWithAge() throws {
        let (age, keygen) = try tools()
        let identity = X25519Identity()
        let keyFile = tmp.appendingPathComponent("ours.txt")
        try "\(identity.string)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        let derived = String(decoding: try run(keygen, ["-y", keyFile.path]), as: UTF8.self)
        XCTAssertEqual(derived.trimmingCharacters(in: .whitespacesAndNewlines), identity.recipient.string)

        // Multiple recipients, one of them from age-keygen.
        let other = tmp.appendingPathComponent("other.txt")
        try run(keygen, ["-o", other.path])
        let otherRecipient = String(decoding: try run(keygen, ["-y", other.path]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plaintext = random(1000)
        let ct = try Age.encrypt(plaintext, to: [identity.recipient, try X25519Recipient(string: otherRecipient)])
        let ctFile = tmp.appendingPathComponent("multi.age")
        try ct.write(to: ctFile)
        XCTAssertEqual(try run(age, ["-d", "-i", keyFile.path, ctFile.path]), plaintext)
        XCTAssertEqual(try run(age, ["-d", "-i", other.path, ctFile.path]), plaintext)
    }
}
