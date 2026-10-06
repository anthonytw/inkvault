import Age
import Foundation
import FuzzSupport
import XCTest

@testable import InkVault
@testable import InkWebDAV

/// A server that answers every request through `inner` and then mutates the
/// response body (and sometimes the status) with a fixed seed.
final class HostileDAV: WebDAVTransport, @unchecked Sendable {
    let inner: MockDAV
    private let lock = NSLock()
    private var rng: FuzzRNG
    private let corpus: [[UInt8]]

    init(inner: MockDAV, seed: UInt64, corpus: [[UInt8]]) {
        self.inner = inner; rng = FuzzRNG(seed: seed); self.corpus = corpus
    }

    func send(_ r: WebDAVRequest) throws -> WebDAVResponse {
        var resp = try inner.send(r)
        lock.lock(); defer { lock.unlock() }
        guard r.method == "PROPFIND" || r.method == "GET", !rng.oneIn(3) else { return resp }
        resp.body = Data(Mutator.mutate([UInt8](resp.body), corpus: corpus, text: r.method == "PROPFIND",
                                        maxSize: 1 << 20, rng: &rng))
        if rng.oneIn(10) { resp.status = rng.pick([200, 207, 301, 404, 500, 999, -1]) }
        if let dump = ProcessInfo.processInfo.environment["INKVAULT_FUZZ_DUMP"] {
            try? resp.body.write(to: URL(fileURLWithPath: dump).appendingPathComponent("hostile-response.last"))
        }
        if let limit = r.maxResponseBytes, resp.body.count > limit {
            throw WebDAVError.responseTooLarge(path: r.url.path, limit: limit)
        }
        return resp
    }
}

/// Seeded fuzzing of what a WebDAV server sends back: PROPFIND multistatus
/// XML (entity expansion, deep nesting, hostile hrefs), the sync state file,
/// and whole sync runs against a server whose every response is mutated.
final class WebDAVFuzzTests: SyncTestCase {
    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    static let laughs: Data = {
        var s = #"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY l0 "lollollollollollollollollollol">"#
        for i in 1...9 { s += "<!ENTITY l\(i) \"" + String(repeating: "&l\(i - 1);", count: 10) + "\">" }
        s += #"]><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/vault/&l9;</d:href></d:response></d:multistatus>"#
        return Data(s.utf8)
    }()

    static let external = Data(#"""
        <?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/passwd">]>
        <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/vault/&x;</d:href></d:response></d:multistatus>
        """#.utf8)

    func testFuzzPropfind() throws {
        let server = MockDAV()
        let vault = try makeVault()
        _ = try delta(vault, device: devA, t: 0, title: "x")
        try sync("A", server)
        let listing = try server.send(WebDAVRequest(method: "PROPFIND", url: URL(string: "https://h/dav/vault/")!,
                                                    headers: ["Depth": "1"])).body
        let notes = try server.send(WebDAVRequest(method: "PROPFIND", url: URL(string: "https://h/dav/vault/notes/")!,
                                                  headers: ["Depth": "1"])).body
        let deep = Data(("<?xml version=\"1.0\"?>" + String(repeating: "<a>", count: 2000)
                         + String(repeating: "</a>", count: 2000)).utf8)
        let base = try client(server)
        assertClean(Fuzz.run("propfind", seeds: [listing, notes, Self.laughs, Self.external, deep], quick: 2500,
                             text: true) { input in
            do {
                let items = try PropfindParser.parse(input)
                if items.contains(where: { $0.href.contains("root:") }) { return "external entity resolved" }
                let stub = Stub(body: input)
                let c = try WebDAVClient(baseURL: base.baseURL, transport: stub)
                _ = try c.list([])
                _ = try c.list(["notes"])
                _ = try c.stat(["vault.json"])
            } catch is WebDAVError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        })
    }

    struct Stub: WebDAVTransport {
        var body: Data
        func send(_ r: WebDAVRequest) throws -> WebDAVResponse { WebDAVResponse(status: 207, body: body) }
    }

    func testFuzzSyncState() throws {
        var state = SyncState()
        state.mutable["vault.json"] = .init(hash: String(repeating: "a", count: 64), stamp: "\"e1\"")
        state.files["7e57c0de-0000-4000-8000-000000000001/17596320000000000-aaaaaaaa-1.delta.age"] =
            .init(included: Included([devA: .init(upTo: 3, extra: [5, 9])]))
        let seed = try JSONEncoder().encode(state)
        let url = tmp.appendingPathComponent("state.json")
        assertClean(Fuzz.run("sync-state", seeds: [seed], quick: 1500, text: true) { input in
            do {
                try input.write(to: url)
                _ = try SyncState.load(url)
            } catch is DecodingError {
            } catch is WebDAVError {
            } catch { return "untyped error \(type(of: error)): \(error)" }
            return nil
        })
    }

    /// Whole sync runs (pull into an empty folder, then two-way with a local
    /// vault) against a server whose listings and files are mutated. Any
    /// error may be thrown; the run must not trap or hang, and whatever it
    /// wrote locally must still open and verify without trapping.
    func testFuzzHostileServer() throws {
        let server = MockDAV()
        let vault = try makeVault()
        for t in 0..<3 { _ = try delta(vault, device: devA, t: Int64(t), title: "t\(t)") }
        var clock = HybridClock()
        try vault.snapshot(noteId: noteID, device: devA, clock: &clock, wall: Date(), app: "fuzz")
        try sync("A", server)
        let corpus = [try vaultJSON("A"), Self.laughs]
        let identity = self.identity
        let root = tmp!
        let counter = Counter()
        assertClean(Fuzz.run("hostile-sync", seeds: [Data([0])], quick: 400) { input in
            var seed: UInt64 = 0xC0FFEE
            for b in input { seed = (seed ^ UInt64(b)) &* 0x100_0000_01B3 }
            let hostile = HostileDAV(inner: server, seed: seed, corpus: corpus.map { [UInt8]($0) })
            let n = counter.next()
            let local = root.appendingPathComponent("pull-\(n).inkvault")
            defer { try? FileManager.default.removeItem(at: local) }
            do {
                let c = try WebDAVClient(baseURL: URL(string: "https://dav.example.com\(MockDAV.base)/")!, transport: hostile)
                for _ in 0..<2 {
                    let v = try? Vault.open(at: local, identities: [identity])
                    _ = try? WebDAVSync(directory: local, vault: v, client: c,
                                        stateURL: root.appendingPathComponent("state-pull-\(n).json"),
                                        options: WebDAVSyncOptions(deviceLabel: "fuzz")).run()
                }
                if let v = try? Vault.open(at: local, identities: [identity]) {
                    _ = v.verify()
                    for id in (try? v.noteIDs()) ?? [] { _ = try? v.summary(of: id) }
                }
            } catch {}
            return nil
        })
    }

    final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}
