import Crypto
import Foundation
import XCTest

@testable import Age

/// Runs every C2SP CCTV age vector in Tests/AgeTests/Vectors (format in the
/// README there), mirroring the reference `testkit_test.go`.
final class CCTVTests: XCTestCase {
    struct Vector {
        var name: String
        var expect = ""
        var payloadHash: Data?
        var fileKey: Data?
        var identities: [any AgeIdentity] = []
        var unparsedIdentities: [String] = []
        var armored = false
        var file = Data()
    }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var it = s.utf8.makeIterator()
        while let a = it.next(), let b = it.next() {
            let pair: String = String(decoding: [a, b], as: UTF8.self)
            let byte: UInt8 = UInt8(pair, radix: 16)!
            out.append(byte)
        }
        return out
    }

    static func parse(name: String, contents: Data) throws -> Vector {
        var v = Vector(name: name)
        var rest = contents[...]
        var compressed = false
        while true {
            guard let nl = rest.firstIndex(of: 0x0A) else { throw XCTSkip("\(name): no payload separator") }
            let line = String(decoding: rest[rest.startIndex..<nl], as: UTF8.self)
            rest = rest[(nl + 1)...]
            if line.isEmpty { break }
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
            let key = parts[0]
            let value = parts.count > 1 ? String(parts[1].dropFirst()) : ""
            switch key {
            case "expect": v.expect = value
            case "payload": v.payloadHash = hex(value)
            case "file key": v.fileKey = hex(value)
            case "identity":
                if let id = try? NativeIdentity(string: value) {
                    v.identities.append(id)
                } else {
                    v.unparsedIdentities.append(value)
                }
            case "passphrase": v.identities.append(ScryptIdentity(passphrase: value))
            case "armored": v.armored = value == "yes"
            case "compressed":
                XCTAssertEqual(value, "zlib", name)
                compressed = true
            case "comment": break
            default: XCTFail("\(name): unknown header key \(key)")
            }
        }
        v.file = compressed ? try zlibUncompress(Data(rest)) : Data(rest)
        return v
    }

    static let headerFailures: Set<AgeError> = [
        .headerParse, .unsupportedVersion, .invalidStanza, .scryptNotAlone, .scryptWorkFactor,
    ]

    func expectedErrors(_ expect: String) -> Set<AgeError>? {
        switch expect {
        case "success": return nil
        case "payload failure": return [.payload]
        case "HMAC failure": return [.headerMAC]
        case "no match": return [.noMatchingIdentity]
        case "header failure": return Self.headerFailures
        case "armor failure": return [.armor]
        default:
            XCTFail("unknown expect \(expect)")
            return []
        }
    }

    func testCCTVVectors() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "Vectors", withExtension: nil))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0 != "README.md" && $0 != "UPSTREAM_COMMIT" }
            .sorted()
        XCTAssertEqual(names.count, 147, "expected the full CCTV set")

        var counts: [String: Int] = [:]
        var hybrid = 0
        for name in names {
            let v = try Self.parse(name: name, contents: Data(contentsOf: dir.appendingPathComponent(name)))
            XCTAssertTrue(v.unparsedIdentities.isEmpty, "\(name): needs an identity we cannot parse")
            if v.identities.contains(where: { ($0 as? NativeIdentity)?.isPostQuantum == true }) { hybrid += 1 }
            check(v)
            counts[v.expect, default: 0] += 1
        }
        // Every MLKEM768-X25519 vector (CCTV "hybrid*") ran with its PQ identity.
        XCTAssertEqual(hybrid, 19)
        let total = counts.values.reduce(0, +)
        XCTAssertEqual(total, 147)
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        print("CCTV: \(total) vectors exercised (\(summary))")
    }

    func check(_ v: Vector) {
        let name = v.name
        let expected = expectedErrors(v.expect)

        // 1. The reference harness path: strip armor explicitly when the
        //    vector says so, then decrypt the binary file chunk by chunk.
        var binary = v.file
        if v.armored {
            do {
                binary = try Armor.decode(v.file)
            } catch {
                XCTAssertEqual(error as? AgeError, .armor, name)
                XCTAssertEqual(v.expect, "armor failure", "\(name): unexpected armor failure")
                return checkPublicAPIFails(v)
            }
            // Armor round trip (README): re-encoding gives the normalised input.
            var norm = [UInt8](v.file)
            norm = Array(String(decoding: norm, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").utf8)
            while let f = norm.first, Armor.isSpace(f) { norm.removeFirst() }
            while let l = norm.last, Armor.isSpace(l) { norm.removeLast() }
            XCTAssertEqual(Armor.encode(binary), Data(norm + [0x0A]), "\(name): armor round trip")
        }

        var released = Data()
        do {
            let fileKey = try AgeFile.decrypt(binary: binary, with: v.identities, released: &released)
            XCTAssertNil(expected, "\(name): expected \(v.expect), got success")
            XCTAssertEqual(fileKey.bytes, v.fileKey, "\(name): file key")
            XCTAssertEqual(Data(SHA256.hash(data: released)), v.payloadHash, "\(name): payload hash")
            // Header encode/decode round trip and STREAM re-encryption (README).
            if let (header, start) = try? AgeFile.parseHeader(binary) {
                let reencoded = try? HeaderCodec.encodeWithoutMAC(header.stanzas)
                    + Array(" \(Base64.encodeRaw(header.mac))\n".utf8)
                XCTAssertEqual(reencoded.map { Data($0) }, binary.prefix(start), "\(name): header round trip")
                let nonce = binary.dropFirst(start).prefix(Stream.nonceSize)
                let key = Stream.payloadKey(fileKey: fileKey, nonce: nonce)
                XCTAssertEqual(
                    try? Stream.encrypt(released, key: key), binary.dropFirst(start + Stream.nonceSize),
                    "\(name): STREAM round trip")
            }
            // The public API (with armor auto-detection) agrees.
            XCTAssertEqual(try? AgeFile.decrypt(v.file, with: v.identities), released, "\(name): public API")
        } catch {
            guard let expected else {
                return XCTFail("\(name): expected success, got \(error)")
            }
            let ageError = error as? AgeError
            XCTAssertTrue(
                ageError.map(expected.contains) ?? false,
                "\(name): expected \(v.expect), got \(error)")
            if v.expect == "payload failure" {
                XCTAssertEqual(
                    Data(SHA256.hash(data: released)), v.payloadHash,
                    "\(name): partial payload hash (\(released.count) bytes released)")
            }
            if v.expect != "header failure", v.expect != "armor failure" {
                XCTAssertNoThrow(try AgeFile.parseHeader(binary), "\(name): header should parse")
            }
            checkPublicAPIFails(v)
        }
    }

    func checkPublicAPIFails(_ v: Vector) {
        XCTAssertThrowsError(try AgeFile.decrypt(v.file, with: v.identities), "\(v.name): public API should fail")
    }
}
