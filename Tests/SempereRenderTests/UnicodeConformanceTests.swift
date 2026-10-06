import Foundation
import Sempere
import XCTest

@testable import SempereRender

/// UAX #9, #14 and #29 against the Unicode conformance files of the version
/// the tables were generated from (`UnicodeTables.version`).
final class UnicodeConformanceTests: XCTestCase {
    static func lines(_ name: String) throws -> [Substring] {
        let gz = try Data(contentsOf: T.fixtureURL("unicode/\(name).gz"))
        let text = String(decoding: try Gzip.decompress(gz), as: UTF8.self)
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    func testTablesVersion() {
        XCTAssertEqual(UnicodeTables.version, "15.1.0")
        XCTAssertEqual(UnicodeProperties.bidiClass[0x05D0], .R)
        XCTAssertEqual(UnicodeProperties.bidiClass[0x0627], .AL)
        XCTAssertEqual(UnicodeProperties.bidiClass[0x0041], .L)
        XCTAssertEqual(UnicodeProperties.bidiClass[0x10FFFF], .BN)
        XCTAssertEqual(UnicodeProperties.lineBreak[0x4E00], .ID)
        XCTAssertEqual(UnicodeProperties.eastAsianWidth[0x4E00], .W)
        XCTAssertEqual(UnicodeProperties.script[0x0627], "Arabic")
        XCTAssertEqual(UnicodeProperties.joiningType[0x0628], .D)
        XCTAssertEqual(UnicodeProperties.brackets[0x28]?.pair, 0x29)
        XCTAssertEqual(UnicodeProperties.mirror[0x28], 0x29)
    }

    func testBidiCharacterTest() throws {
        var checked = 0, failures = 0
        for line in try Self.lines("BidiCharacterTest.txt") {
            let f = line.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 5 else { continue }
            let cps = f[0].split(separator: " ").compactMap { UInt32($0, radix: 16) }
            let dir = Int(f[1])!
            let p = BidiParagraph(cps, direction: dir == 2 ? nil : dir)
            let expectedLevels = f[3].split(separator: " ").map { $0 == "x" ? nil : Int($0) }
            let expectedOrder = f[4].split(separator: " ").compactMap { Int($0) }
            let levels = p.lineLevels(0..<cps.count)
            var ok = p.level == Int(f[2])!
            for (i, e) in expectedLevels.enumerated() where e != nil { ok = ok && Int(levels[i]) == e! }
            let order = p.visualOrder(0..<cps.count).filter { expectedLevels[$0] != nil }
            ok = ok && order == expectedOrder
            if !ok {
                failures += 1
                if failures <= 10 { XCTFail("\(line): level \(p.level) levels \(levels) order \(order)") }
            }
            checked += 1
        }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(checked, 90_000)
    }

    /// `BidiTest.txt` (classes only, every paragraph direction), from the
    /// system's UCD when installed.
    func testBidiTest() throws {
        let url = URL(fileURLWithPath: "/usr/share/unicode/BidiTest.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("no /usr/share/unicode/BidiTest.txt") }
        guard text.contains("BidiTest-15.1") else { throw XCTSkip("system UCD is another version") }
        var levels: [Int?] = [], order: [Int] = []
        var checked = 0, failures = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.isEmpty {
            if line.hasPrefix("@Levels:") {
                levels = line.dropFirst(8).split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0 == "x" ? nil : Int($0) }
                continue
            }
            if line.hasPrefix("@Reorder:") {
                order = line.dropFirst(9).split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
                continue
            }
            if line.hasPrefix("@") { continue }
            let f = line.split(separator: ";")
            let classes = f[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).map { BidiClass(rawValue: String($0))! }
            let bits = Int(f[1].trimmingCharacters(in: .whitespaces))!
            for (bit, dir) in [(1, nil), (2, 0), (4, 1)] as [(Int, Int?)] where bits & bit != 0 {
                let p = BidiParagraph([], classes: classes, direction: dir)
                let got = p.lineLevels(0..<classes.count)
                var ok = true
                for (i, e) in levels.enumerated() where e != nil { ok = ok && Int(got[i]) == e! }
                let o = p.visualOrder(0..<classes.count).filter { levels[$0] != nil }
                ok = ok && o == order
                if !ok {
                    failures += 1
                    if failures <= 10 { XCTFail("\(line) dir \(String(describing: dir)): \(got) \(o), expected \(levels) \(order)") }
                }
                checked += 1
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(checked, 400_000)
    }
}
