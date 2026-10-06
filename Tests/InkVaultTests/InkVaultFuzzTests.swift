import Age
import Foundation
import FuzzSupport
import XCTest

@testable import InkVault

/// Seeded mutation fuzzing of everything `Sources/InkVault` parses from a vault
/// folder: body framing and gzip, revision / snapshot / manifest / journal /
/// device-state JSON, file names and the other string encodings, and the
/// reducer, history, snapshot and compaction code fed with adversarial op logs.
/// Every input may fail with a typed error; none may trap, hang or allocate
/// without bound. Knobs: Tests/FuzzSupport (INKVAULT_FUZZ_LONG, ...).
final class InkVaultFuzzTests: VaultTestCase {
    static let wall = Date(timeIntervalSince1970: 1_800_000_000)
    static let pageA = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a1")!
    static let pageB = UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000a2")!

    func assertClean(_ report: FuzzReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(report.cases, 0, file: file, line: line)
        for f in report.failures { XCTFail("\(f)", file: file, line: line) }
    }

    /// Errors the library is allowed to throw for bad input.
    static func typed(_ body: () throws -> Void) -> String? {
        do { try body() } catch is DecodingError {
        } catch is EncodingError {
        } catch is NoteLogError {
        } catch is HistoryError {
        } catch is VaultError {
        } catch is RevisionReadError {
        } catch is BodyFramingError {
        } catch is GzipError {
        } catch is AgeError {
        } catch { return "untyped error \(type(of: error)): \(error)" }
        return nil
    }

    // MARK: Seeds

    static func richStroke(_ id: UUID, _ n: Int, transform: Transform? = nil, parent: UUID? = nil) -> Stroke {
        Stroke(id: id, ink: Ink(tool: n % 2 == 0 ? .pen : .marker, color: Color(r: 10, g: 20, b: 30, a: 200), width: 2.5),
               points: (0..<n).map { i in
                   StrokePoint(x: Double(i) * 3.5, y: 10 + Double(i % 7), t: Double(i) / 120, w: 2, h: 2.5, o: 0.9,
                               f: 0.5, az: 0.25, al: 1.25)
               }, transform: transform, parent: parent)
    }

    /// A log with every op kind, two devices, a snapshot with extras,
    /// tombstones and clocks, and a later delta.
    static func seedLog() throws -> [Revision] {
        var log = LogBuilder()
        let s = (1...6).map { UUID(uuidString: "7e57c0de-0000-4000-8000-0000000000b\($0)")! }
        let rec = Recognition(engine: "fuzz-1", text: "hello world",
                              words: [.init(text: "hello", box: .init(x: 1, y: 2, w: 30, h: 10))])
        let d1 = log.delta(devA, 0, NoteOps.newNote(title: "Fuzz", notebook: "School/Math", tags: ["a", "b"], pageId: pageA))
        let d2 = log.delta(devA, 10, [.addStroke(page: pageA, stroke: richStroke(s[0], 5)),
                                      .addStroke(page: pageA, stroke: richStroke(s[1], 2, transform: .init(a: 2, b: 0, c: 0, d: 2, tx: 5, ty: 6))),
                                      .addPage(Page(id: pageB, order: "b", parent: pageA)),
                                      .setPageRecognition(pageId: pageA, recognition: rec)])
        let d3 = log.delta(devB, 15, [.removeStroke(page: pageA, strokeId: s[0]), .setPageOrder(pageId: pageB, order: "Z"),
                                      .setMeta(.paper(Paper(kind: .grid, spacing: 18))),
                                      .setMeta(.pageSize(PageSize(width: 612, height: 2000, infinite: true, breakHeight: 700)))])
        let snap = try log.snapshot(devB, 20, from: [d1, d2, d3])
        let d4 = log.delta(devA, 30, [.addStroke(page: pageB, stroke: richStroke(s[2], 40, parent: s[1])),
                                      .removePage(pageId: pageA), .deleteNote, .restoreNote,
                                      .setMeta(.favorite(true)), .setMeta(.notebook(nil))])
        var late = log.delta(devB, 40, [.addStroke(page: pageB, stroke: richStroke(s[3], 1))])
        late.seq = 7   // leaves a gap: a later snapshot lists it in `extra`
        let snap2 = try log.snapshot(devA, 50, from: [d1, d2, d3, snap, d4, late])
        return [d1, d2, d3, snap, d4, late, snap2]
    }

    static func json(_ value: some Encodable) throws -> Data { try InkJSON.encoder().encode(value) }

    // MARK: Exercising the model

    /// Runs everything that consumes a decoded log: reconstruct, history,
    /// restore, snapshot (and its re-encoding), compaction, notebook tree,
    /// page-order keys.
    static func exercise(_ revs: [Revision]) -> String? {
        typed {
            guard !revs.isEmpty else { return }
            _ = NoteHistory.restorePoints(revs)
            _ = LoadedNote(revisions: revs, failures: [:]).compactionPlan(retention: 0, now: wall, assumingSnapshot: true)
            _ = LoadedNote(revisions: revs, failures: [:]).needsSnapshotBeforeCompaction(retention: 0, now: wall)
            let state = try NoteReducer.reconstruct(revs)
            _ = NotebookNode.flatten(NotebookNode.tree([state.meta.notebook, "x/y"]))
            for (a, b) in zip(state.pages.map(\.order), state.pages.dropFirst().map(\.order)) {
                _ = PageOrder.between(a, b); _ = PageOrder.between(b, a)
            }
            _ = PageOrder.between(state.pages.last?.order, nil)
            _ = PageOrder.between(nil, state.pages.first?.order)
            let names = revs.map(\.name).sorted()
            for point in [names[0], names[names.count / 2]] {
                var clock = HybridClock()
                _ = try? NoteHistory.makeRestore(from: revs, to: point, device: devC, clock: &clock, wall: wall,
                                                 app: "fuzz")
            }
            var clock = HybridClock()
            let seq = Vault.nextSeq(from: revs, device: devC)
            guard seq <= RevisionName.maxSeq else { return }
            let snap = try SnapshotBuilder.makeSnapshot(from: revs, device: devC, seq: seq, clock: &clock, wall: wall,
                                                        app: "fuzz")
            let back = try InkJSON.decoder().decode(Revision.self, from: json(snap))
            _ = try NoteReducer.reconstruct(revs + [back])
        }
    }

    /// One revision decoded from `input`, merged with the seed log.
    static func exerciseRevision(_ input: Data, log: [Revision]) -> String? {
        let rev: Revision
        do { rev = try InkJSON.decoder().decode(Revision.self, from: input) } catch is DecodingError { return nil } catch {
            return "untyped decode error \(type(of: error)): \(error)"
        }
        if let p = exercise([rev]) { return p }
        // Same (device, seq) as a seed revision is a typed conflict; keep the rest.
        return exercise(log.filter { $0.device != rev.device || $0.seq != rev.seq } + [rev])
    }

    // MARK: Targets

    func testFuzzRevisionJSON() throws {
        let log = try Self.seedLog()
        let seeds = try log.map(Self.json)
        assertClean(Fuzz.run("revision-json", seeds: seeds, quick: 1500, text: true) { input in
            Self.exerciseRevision(input, log: log)
        })
    }

    /// Whole op logs as one JSON array, half of them generated: duplicate
    /// ids, removes of unknown ids, parent cycles, orphans, conflicting
    /// (device, seq), huge `included`, many pages and long strokes.
    func testFuzzOpLogs() throws {
        let log = try Self.seedLog()
        let seeds = [try Self.json(log), try Self.json(Array(log.prefix(3)))]
        assertClean(Fuzz.run("op-log", seeds: seeds, quick: 800, text: true, generate: { rng in
            (try? Self.json(Self.adversarialLog(&rng))) ?? Data()
        }) { input in
            let revs: [Revision]
            do { revs = try InkJSON.decoder().decode([Revision].self, from: input) } catch is DecodingError { return nil } catch {
                return "untyped decode error \(type(of: error))"
            }
            return Self.exercise(revs)
        })
    }

    func testFuzzBodyFramingAndGzip() throws {
        let log = try Self.seedLog()
        let secret = VaultSecret.random()
        let note = testNote.uuidString.lowercased()
        let seeds = try log.map { r in
            try BodyFraming.frame(json: Self.json(r), noteId: note, filename: r.name.filename, secret: secret)
        }
        assertClean(Fuzz.run("body-framing", seeds: seeds, quick: 2500) { input in
            Self.typed {
                for key in [secret, nil] {
                    guard let u = try? BodyFraming.unframe(input, noteId: note, filename: log[0].name.filename,
                                                           secret: key) else { continue }
                    let json = try Gzip.decompress(u.gzip, maxOutput: 32 << 20)
                    if let p = Self.exerciseRevision(json, log: log) { throw Invariant(p) }
                }
            }
        })
        // Raw gzip members, including ones that inflate far past the limit.
        let big = try Gzip.compress(Data(count: 12 << 20))
        let gz = try seeds.map { _ = $0; return try Gzip.compress(Self.json(log)) } + [big]
        assertClean(Fuzz.run("gzip", seeds: gz, quick: 2000, maxSize: 256 << 10) { input in
            Self.typed {
                _ = try Gzip.decompress(input, maxOutput: 8 << 20)
                _ = try Gzip.inflateRaw(input.dropFirst(10), maxOutput: 8 << 20)
            }
        })
    }

    struct Invariant: Error { var text: String; init(_ t: String) { text = t } }

    func testFuzzManifestJournalAndDeviceState() throws {
        let id = X25519Identity(), other = X25519Identity()
        let vault = try Vault.create(at: vaultURL(), recipients: [id.recipient, other.recipient], labels: ["a", "b"],
                                     identities: [id])
        let manifest = try Data(contentsOf: vault.url.appendingPathComponent("vault.json"))
        let journal = try Self.json(Vault.RewrapJournal(format: "inkvault/1",
                                                        previousVaultSecret: try Vault.encryptSecret(.random(), to: [id.recipient])))
        let device = try JSONEncoder().encode(DeviceState(device: devA, clock: HybridClock(millis: 5, counter: 3)))
        assertClean(Fuzz.run("manifest", seeds: [manifest, journal, device], quick: 1500, text: true) { input in
            Self.typed {
                if let m = try? Vault.readManifest(input) {
                    _ = try? Vault.decryptSecret(m.vaultSecret, with: [id])
                    _ = try m.encoded()
                }
                _ = try? InkJSON.decoder().decode(Vault.RewrapJournal.self, from: input)
                if let s = try? JSONDecoder().decode(DeviceState.self, from: input) {
                    var clock = s.clock
                    _ = clock.tick(wall: Self.wall)
                    _ = clock.observe(HLC(millis: HLC.maxMillis, counter: HLC.maxCounter)!, wall: .distantFuture)
                }
            }
        })
    }

    /// File names and the other string encodings (origin, stamps, colours,
    /// page-order keys, notebook paths).
    func testFuzzNamesAndStrings() throws {
        let seeds = ["17596320000000003-a1b2c3d4-12.delta.age", "17596320000000003-a1b2c3d4-1.snapshot.age",
                     "17596320000000003-a1b2c3d4-12-0", "17596320000000003-a1b2c3d4", "#1A1A1AFF", "a0V",
                     " Research//Daily log/ "].map { Data($0.utf8) }
        assertClean(Fuzz.run("names", seeds: seeds, quick: 6000, text: true, maxSize: 8192) { input in
            let s = String(decoding: input, as: UTF8.self)
            if let n = RevisionName(s), n.seq > RevisionName.maxSeq { return "seq above maxSeq accepted" }
            _ = Origin(s); _ = Stamp(s); _ = HLC(s); _ = DeviceID(s); _ = Color(hex: s)
            let half = s.index(s.startIndex, offsetBy: s.count / 2)
            let (a, b) = (String(s[..<half]), String(s[half...]))
            for (x, y) in [(a, b), (b, a), (s, s)] {
                let k = PageOrder.between(x, y)
                if PageOrder.strictlyBetween(x, y) != nil, !(x < k && k < y) { return "between(\(x), \(y)) = \(k)" }
            }
            _ = PageOrder.between(s, nil); _ = PageOrder.between(nil, s)
            _ = NotebookNode.tree([s, a, b])
            _ = NotebookPath.renamed(s, from: a, to: b)
            return nil
        })
    }

    /// Mutated revisions, encrypted and written into a real vault, then read
    /// through every vault entry point (load, reconstruct, summary, history,
    /// verify, nextSeq, snapshot, compaction plan).
    func testFuzzVaultFiles() throws {
        let id = X25519Identity()
        let vault = try makeVault(id)
        let log = try Self.seedLog()
        for r in log { try vault.write(r) }
        let seeds = try log.map(Self.json)
        let dir = vault.url.appendingPathComponent("notes").appendingPathComponent(testNote.uuidString.lowercased())
        let secret = try XCTUnwrap(vault.secret)
        assertClean(Fuzz.run("vault-files", seeds: seeds, quick: 250, text: true) { input in
            // Written under the name it claims (or a fixed one), encrypted for real.
            let claimed = (try? InkJSON.decoder().decode(Revision.self, from: input))?.name
            let name = claimed ?? RevisionName("17596320000500000-cccccccc-9.delta.age")!
            let file = dir.appendingPathComponent(name.filename)
            guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
            defer { try? FileManager.default.removeItem(at: file) }
            return Self.typed {
                let gz = try Gzip.compress(input)
                let body = BodyFraming.frame(gzip: gz, noteId: testNote.uuidString.lowercased(), filename: name.filename,
                                             secret: secret)
                try AgeFile.encrypt(body, to: [id.recipient]).write(to: file)
                let loaded = try vault.loadNote(testNote)
                _ = vault.summary(of: testNote, loaded: loaded)
                _ = loaded.restorePoints
                _ = loaded.history
                _ = try? vault.nextSeq(noteId: testNote, device: devC)
                _ = try? vault.reconstruct(loaded)
                _ = loaded.compactionPlan(retention: 0, now: Self.wall, assumingSnapshot: true)
                _ = vault.verify()
                if let p = Self.exercise(loaded.revisions) { throw Invariant(p) }
            }
        })
    }

    // MARK: Adversarial log generator

    static func adversarialLog(_ rng: inout FuzzRNG) -> [Revision] {
        let pages = (0..<4).map { UUID(uuidString: "7e57c0de-0000-4000-8000-00000000000\($0)")! }
        let strokes = (0..<8).map { UUID(uuidString: "7e57c0de-0000-4000-8000-0000000001\(String(format: "%02d", $0))")! }
        let devices = [devA, devB, devC]
        let orders = ["a", "b", "", "Z", "a0", "zzzz", "\u{0}", "é", "a/b"]
        var seqs: [DeviceID: Int] = [:]
        var out: [Revision] = []
        let count = 1 + rng.below(12)
        for k in 0..<count {
            let dev = rng.pick(devices)
            var seq = (seqs[dev] ?? 0) + 1
            if rng.oneIn(6) { seq = rng.pick([1, 2, RevisionName.maxSeq, RevisionName.maxSeq - 1, seq + 1000]) }
            seqs[dev] = min(seq, RevisionName.maxSeq - 1)
            let hlc = HLC(millis: rng.oneIn(8) ? HLC.maxMillis : baseMillis + Int64(rng.below(1000)),
                          counter: rng.oneIn(8) ? HLC.maxCounter : rng.below(3))!
            var ops: [Op] = []
            let n = rng.oneIn(20) ? 300 + rng.below(700) : rng.below(8)
            for _ in 0..<n {
                let p = rng.pick(pages), s = rng.pick(strokes)
                switch rng.below(10) {
                case 0: ops.append(.addPage(Page(id: p, order: rng.pick(orders), parent: rng.oneIn(2) ? rng.pick(pages) : nil)))
                case 1: ops.append(.removePage(pageId: p))
                case 2, 3:
                    let len = rng.oneIn(200) ? 5000 : 1 + rng.below(6)
                    ops.append(.addStroke(page: p, stroke: richStroke(s, len, parent: rng.oneIn(3) ? rng.pick(strokes) : nil)))
                case 4: ops.append(.removeStroke(page: p, strokeId: s))
                case 5: ops.append(.setPageOrder(pageId: p, order: rng.pick(orders)))
                case 6: ops.append(.setPageRecognition(pageId: p, recognition: rng.oneIn(2) ? nil
                                                       : Recognition(engine: "x", text: "t")))
                case 7: ops.append(.setMeta(rng.pick([.title("t"), .tags(["x", "x"]), .notebook("a//b/"), .favorite(true),
                                                      .paper(Paper(kind: .dot, spacing: 0.001)),
                                                      .pageSize(PageSize(width: 1e300, height: -1, infinite: true))])))
                case 8: ops.append(rng.oneIn(2) ? .deleteNote : .restoreNote)
                default: ops.append(.addPage(Page(id: UUID(), order: "p\(k)")))
                }
            }
            let body: Revision.Body
            if rng.oneIn(3) {
                var included = Included()
                for d in devices where rng.oneIn(2) {
                    let up = rng.pick([0, 1, 3, RevisionName.maxSeq, RevisionName.maxSeq - 1])
                    let extra = (0..<rng.below(4)).map { _ in rng.pick([2, 5, 9, RevisionName.maxSeq, 100_000]) }
                    included = included.union(Included([d: .init(upTo: up, extra: extra)]))
                }
                let pageList = (0..<(rng.oneIn(20) ? 2000 : rng.below(4))).map { i in
                    Page(id: i < pages.count ? pages[i] : UUID(), order: rng.pick(orders),
                         strokes: rng.oneIn(2) ? [richStroke(rng.pick(strokes), 3)] : [],
                         orderClock: rng.oneIn(2) ? "\(hlc)-\(dev)" : rng.pick(["garbage", "99999999999999999-ffffffff"]),
                         origin: rng.pick([nil, "\(hlc)-\(dev)-1-0", "\(hlc)-\(dev)-\(RevisionName.maxSeq)-9223372036854775807",
                                           "x"]),
                         recognitionClock: rng.oneIn(3) ? "00000000000000000-00000000" : nil)
                }
                let state = NoteState(deleted: rng.oneIn(2), meta: NoteMeta(created: wall), pages: pageList,
                                      clocks: rng.oneIn(2) ? ["title": "99999999999999999-ffffffff", "bogus": "x"] : nil,
                                      tombstones: rng.oneIn(2) ? Tombstones(strokes: strokes, pages: [pages[0]]) : nil)
                body = .snapshot(included: included, state: state)
            } else {
                body = .delta(ops: ops)
            }
            out.append(Revision(noteId: testNote, device: dev, seq: seq, hlc: hlc,
                                wall: rng.oneIn(5) ? .distantFuture : wall, app: "fuzz", body: body))
            if rng.oneIn(40), let last = out.last {
                var dup = last
                dup.app = "conflicting copy"
                out.append(dup)
            }
        }
        return out
    }
}
