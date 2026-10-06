import FuzzSupport
import Foundation
import XCTest

@testable import Sempere

/// `AudioProbe` reads real MPEG-4 audio written by ffmpeg (Fixtures/audio) and
/// refuses damaged or hostile files with a typed error.
final class AudioProbeTests: XCTestCase {
    static let audio = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/audio")

    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: audio.appendingPathComponent(name)) }

    func testAACLCWithMoovAfterTheSamples() throws {
        let info = try AudioProbe.probe(file: Self.audio.appendingPathComponent("tone-aac.m4a"))
        XCTAssertEqual(info.codec, "aac")
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(try XCTUnwrap(info.duration), 2.5, accuracy: 0.05)
        // Average over the whole file: about 69 kbit/s (64 kbit/s payload plus framing).
        XCTAssertEqual(Double(try XCTUnwrap(info.bitRate)), 69_000, accuracy: 6_000)
    }

    func testFaststartFileGivesTheSameAnswer() throws {
        XCTAssertEqual(try AudioProbe.probe(try Self.fixture("tone-aac-faststart.m4a")),
                       try AudioProbe.probe(try Self.fixture("tone-aac.m4a")))
    }

    func testALAC() throws {
        let info = try AudioProbe.probe(try Self.fixture("tone-alac.m4a"))
        XCTAssertEqual(info.codec, "alac")
        XCTAssertEqual(info.sampleRate, 44100)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(try XCTUnwrap(info.duration), 1.0, accuracy: 0.05)
    }

    func testNotMPEG4() {
        XCTAssertThrowsError(try AudioProbe.probe(Data("RIFF....WAVEfmt ".utf8))) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
        XCTAssertThrowsError(try AudioProbe.probe(Data())) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
        XCTAssertThrowsError(try AudioProbe.probe(Data(repeating: 0, count: 7))) { XCTAssertEqual($0 as? AudioProbeError, .notMP4) }
    }

    func testTruncatedAndLyingFiles() throws {
        let good = try Self.fixture("tone-aac-faststart.m4a")
        // Cut inside moov, inside ftyp and right after ftyp: typed errors, never a trap.
        for cut in [20, 28, 40, 100, 500, 1200] {
            XCTAssertThrowsError(try AudioProbe.probe(good.prefix(cut)), "cut at \(cut)") { XCTAssertTrue($0 is AudioProbeError, "\($0)") }
        }
        // A moov box claiming 4 GiB, and a box smaller than its own header.
        var big = Array(good.prefix(28)) + [0xFF, 0xFF, 0xFF, 0xF0] + Array("moov".utf8) + [UInt8](repeating: 0, count: 64)
        XCTAssertThrowsError(try AudioProbe.probe(Data(big))) { XCTAssertEqual($0 as? AudioProbeError, .malformed("moov box too large or cut off")) }
        big = Array(good.prefix(28)) + [0, 0, 0, 4] + Array("free".utf8)
        XCTAssertThrowsError(try AudioProbe.probe(Data(big))) { XCTAssertTrue($0 is AudioProbeError) }
        // An MP4 with only a file type box is an unfinished recording.
        XCTAssertThrowsError(try AudioProbe.probe(good.prefix(28)))
    }

    func testATruncatedSampleBoxStillHasItsHeader() throws {
        // moov comes first: a recording cut off inside mdat is still described.
        let good = try Self.fixture("tone-aac-faststart.m4a")
        XCTAssertEqual(try AudioProbe.probe(good.prefix(1300)).codec, "aac")
    }

    func testFlippedBytesNeverTrap() throws {
        let good = try Self.fixture("tone-aac-faststart.m4a")
        for i in 0..<400 {   // the headers and moov
            var d = good
            d[i] ^= 0xFF
            _ = try? AudioProbe.probe(d)
        }
    }

    func testFuzz() throws {
        let seeds = try ["tone-aac.m4a", "tone-aac-faststart.m4a", "tone-alac.m4a"].map(Self.fixture)
        let report = Fuzz.run("audio-probe", seeds: seeds, quick: 400, maxSize: 64 << 10) { input in
            do { _ = try AudioProbe.probe(input) } catch is AudioProbeError {} catch { return "untyped error: \(error)" }
            return nil
        }
        XCTAssertGreaterThan(report.cases, 0)
        for f in report.failures { XCTFail("\(f)") }
    }
}
