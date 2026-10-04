import Age
import Foundation
import InkVault
import XCTest

/// Result of one `inkvault` run.
struct CLIResult {
    var status: Int32
    var out: String
    var err: String
    var outData: Data
    var json: Any? { try? JSONSerialization.jsonObject(with: outData) }
}

/// Base class: a scratch directory per test, subprocess helper, fixture access.
class CLITestCase: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("inkvault-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("InkVaultTests/Fixtures")
    static var fixtureVault: String { fixtures.appendingPathComponent("sample.inkvault").path }
    static var fixtureKey: String { fixtures.appendingPathComponent("sample.key").path }
    static let passphrase = "inkvault-test"
    static let lecture = "11111111-1111-4111-8111-111111111111"

    /// Runs the binary with a clean INKVAULT_* environment.
    @discardableResult
    func cli(_ args: [String], env: [String: String] = [:]) throws -> CLIResult {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("INKVAULT_") }
        environment["XDG_STATE_HOME"] = tmp.appendingPathComponent("state").path
        environment.merge(env) { $1 }
        let p = Process()
        p.executableURL = CLISmokeTests.binary
        p.arguments = args
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Drain both pipes before waiting so a large output cannot deadlock.
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return CLIResult(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: box.get(), as: UTF8.self), outData: outData)
    }

    func path(_ name: String) -> String { tmp.appendingPathComponent(name).path }

    /// A writable copy of the fixture vault.
    func copyFixtureVault(as name: String = "copy.inkvault") throws -> String {
        let dest = tmp.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.fixtureVault), to: dest)
        return dest.path
    }

    func fixtureIdentity() throws -> X25519Identity {
        try IdentityFile.parse(String(contentsOfFile: Self.fixtureKey, encoding: .utf8))
    }

    /// Creates a vault through the library and writes a two-page note plus a
    /// one-page note. Returns the vault, the identity and the key file path.
    func makeVault(named name: String = "mine.inkvault") throws -> (vault: Vault, identity: X25519Identity, keyPath: String) {
        let id = X25519Identity()
        let keyPath = path("\(name).key")
        try IdentityFile.render(id, created: Date()).write(toFile: keyPath, atomically: true, encoding: .utf8)
        let vault = try Vault.create(at: tmp.appendingPathComponent(name), recipients: [id.recipient],
                                     labels: ["laptop"], identities: [id])
        let device = DeviceID("abcdef01")!
        func stroke(_ n: Double) -> Stroke {
            var pts: [StrokePoint] = []
            for i in 0..<5 {
                let k = Double(i)
                pts.append(StrokePoint(x: 40 + n * 10 + k * 12, y: 100 + k * 9, t: k * 0.02, w: 2.5, h: 2.5))
            }
            return Stroke(ink: Ink(tool: .pen, color: .black, width: 2.5), points: pts)
        }
        func rev(_ note: UUID, _ seq: Int, _ ms: Int64, _ ops: [Op]) -> Revision {
            Revision(noteId: note, device: device, seq: seq, hlc: HLC(millis: 1_760_000_000_000 + ms, counter: 0)!,
                     wall: Date(timeIntervalSince1970: Double(1_760_000_000_000 + ms) / 1000),
                     app: "cli-test/1", body: .delta(ops: ops))
        }
        let n1 = UUID(uuidString: "aaaaaaaa-1111-4111-8111-000000000001")!
        let n2 = UUID(uuidString: "bbbbbbbb-2222-4222-8222-000000000002")!
        let p1 = UUID(), p2 = UUID(), p3 = UUID()
        try vault.write(rev(n1, 1, 1000, [.addPage(Page(id: p1, order: "a0")), .setMeta(.title("Physics / Week 3")),
                                          .setMeta(.tags(["physics"])), .setMeta(.paper(.ruled)),
                                          .addStroke(page: p1, stroke: stroke(1))]))
        try vault.write(rev(n1, 2, 2000, [.addPage(Page(id: p2, order: "a1")), .addStroke(page: p2, stroke: stroke(2)),
                                          .addStroke(page: p2, stroke: stroke(3))]))
        try vault.write(rev(n2, 1, 3000, [.addPage(Page(id: p3, order: "a0")), .setMeta(.title("Groceries")),
                                          .addStroke(page: p3, stroke: stroke(4))]))
        return (vault, id, keyPath)
    }
}

/// A lock-protected Data cell for handing a pipe's contents between threads.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
