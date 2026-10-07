import Foundation
import Sempere
import XCTest

/// `sempere transcribe`. Transcription needs the Speech framework: on Linux
/// the command must refuse and change nothing (`--dry-run` and `--check`
/// work); on macOS it may run, and whatever it stores must be a valid
/// transcript of the right recording. No test asserts what a recogniser
/// hears in a synthetic tone.
final class CLITranscribeTests: CLITestCase {
    static let tone = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SempereTests/Fixtures/audio/tone-aac.m4a").path
    let physics = "aaaaaaaa-1111-4111-8111-000000000001"

    func setUp(recordings titles: [String]) throws -> (vault: Vault, args: [String], ids: [String]) {
        let (vault, _, keyPath) = try makeVault()
        let args = ["--vault", vault.url.path, "--identity", keyPath]
        var ids: [String] = []
        for t in titles {
            let r = try cli(["attach", "recording", physics, Self.tone, "--title", t, "--json"] + args)
            XCTAssertEqual(r.status, 0, r.err)
            ids.append(try XCTUnwrap(((r.json as? [String: Any])?["recording"] as? [String: Any])?["id"] as? String))
        }
        return (vault, args, ids)
    }

    func revisionCount(_ vault: Vault) throws -> Int {
        try vault.noteIDs().reduce(0) { $0 + (try vault.revisionNames(of: $1).count) }
    }

    func listed(_ r: CLIResult) throws -> [String] {
        let notes = try XCTUnwrap((r.json as? [String: Any])?["notes"] as? [[String: Any]], r.out + r.err)
        return notes.flatMap { ($0["recordings"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } }
    }

    func testCheckReportsEnginesWithoutAVault() throws {
        let r = try cli(["transcribe", "--check", "--json"])
        XCTAssertEqual(r.status, 0, r.err)
        let engines = try XCTUnwrap((r.json as? [String: Any])?["engines"] as? [[String: Any]])
        XCTAssertEqual(engines.count, 2)
        XCTAssertTrue(engines.allSatisfy { ($0["engine"] as? String)?.hasPrefix("apple-") ?? false })
        #if !canImport(Speech)
        XCTAssertEqual((r.json as? [String: Any])?["supported"] as? Bool, false)
        #endif
    }

    func testDryRunSelectsRecordingsWithoutATranscript() throws {
        let (vault, args, ids) = try setUp(recordings: ["One", "Two"])
        let before = try revisionCount(vault)
        let all = try cli(["transcribe", physics, "--dry-run", "--json"] + args)
        XCTAssertEqual(all.status, 0, all.err)
        XCTAssertEqual(Set(try listed(all)), Set(ids))

        // A recording that has a transcript is skipped unless --force.
        let transcript = path("t.json")
        try Transcript(recording: UUID(uuidString: ids[0])!, engine: "test", language: "en", created: Date(),
                       segments: [.init(start: 0, end: 1, text: "hello")]).encoded().write(to: URL(fileURLWithPath: transcript))
        XCTAssertEqual(try cli(["attach", "transcript", physics, ids[0], transcript] + args).status, 0)
        let after = try revisionCount(vault)
        XCTAssertEqual(try listed(try cli(["transcribe", physics, "--dry-run", "--json"] + args)), [ids[1]])
        XCTAssertEqual(Set(try listed(try cli(["transcribe", physics, "--force", "--dry-run", "--json"] + args))), Set(ids))
        XCTAssertEqual(try listed(try cli(["transcribe", physics, "One", "--dry-run", "--json"] + args)), [ids[0]],
                       "a named recording is read whatever it has")
        XCTAssertEqual(try listed(try cli(["transcribe", "--all", "--dry-run", "--json"] + args)), [ids[1]])
        let text = try cli(["transcribe", physics, "--dry-run"] + args)
        XCTAssertTrue(text.out.contains("would transcribe recording \(ids[1].prefix(8)) Two"), text.out)
        XCTAssertEqual(try revisionCount(vault), after, "a dry run writes nothing")
        XCTAssertEqual(after, before + 1)
    }

    func testUsageErrors() throws {
        let (_, args, _) = try setUp(recordings: [])
        for bad in [["transcribe"], ["transcribe", "--all", physics], ["transcribe", "--all", "x", "y"],
                    ["transcribe", physics, "--engine", "whisper"], ["transcribe", physics, "--language", "not a tag"]] {
            XCTAssertEqual(try cli(bad + args).status, 2, "\(bad)")
        }
        let missing = try cli(["transcribe", physics, "nope", "--dry-run"] + args)
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.err.contains("no recording nope"), missing.err)
    }

    func testTranscribeRefusesWithoutSpeechOrStoresAValidTranscript() throws {
        let (vault, args, ids) = try setUp(recordings: ["Tone"])
        let before = try revisionCount(vault)
        let r = try cli(["transcribe", physics, "--engine", "speechtranscriber", "--no-download", "--json"] + args)
        #if canImport(Speech)
        // macOS: the model may be missing on a CI runner (then exit 1); a run that worked stored a valid transcript.
        if r.status == 0 {
            let state = try vault.reconstruct(noteId: UUID(uuidString: physics)!)
            let rec = try XCTUnwrap(state.recordings.first { $0.id.uuidString.lowercased() == ids[0] })
            let ref = try XCTUnwrap(rec.transcript)
            let transcript = try Transcript.decode(try vault.readBlob(note: UUID(uuidString: physics)!, ref))
            XCTAssertEqual(transcript.recording.uuidString.lowercased(), ids[0])
            XCTAssertTrue(transcript.engine.hasPrefix("apple-speechtranscriber-"))
            XCTAssertEqual(try revisionCount(vault), before + 1)
        } else {
            XCTAssertEqual(r.status, 1, r.err)
        }
        #else
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("Speech framework"), r.err)
        XCTAssertEqual(try revisionCount(vault), before, "nothing written")
        #endif
    }
}
