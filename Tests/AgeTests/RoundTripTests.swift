import Foundation
import XCTest

@testable import Age

final class RoundTripTests: XCTestCase {
    static let sizes = [0, 1, 64 * 1024, 64 * 1024 + 1, 200 * 1024 + 7]

    func random(_ n: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    func testX25519RoundTrips() throws {
        let id = X25519Identity()
        for size in Self.sizes {
            let plaintext = random(size)
            for armor in [false, true] {
                let ct = try Age.encrypt(plaintext, to: [id.recipient], armor: armor)
                XCTAssertEqual(Armor.isArmored(ct), armor)
                XCTAssertEqual(try Age.decrypt(ct, with: [id]), plaintext, "size \(size) armor \(armor)")
            }
        }
    }

    func testScryptRoundTrips() throws {
        // Low work factor keeps the debug suite fast; the format is identical.
        let recipient = ScryptRecipient(passphrase: "correct horse battery staple", workFactor: 10)
        let identity = ScryptIdentity(passphrase: "correct horse battery staple")
        for size in Self.sizes {
            let plaintext = random(size)
            for armor in [false, true] {
                let ct = try Age.encrypt(plaintext, to: [recipient], armor: armor)
                XCTAssertEqual(try Age.decrypt(ct, with: [identity]), plaintext, "size \(size) armor \(armor)")
            }
        }
        let ct = try Age.encrypt(Data("x".utf8), to: [recipient])
        let (header, _) = try Age.parseHeader(ct)
        XCTAssertEqual(header.stanzas.count, 1)
        XCTAssertEqual(header.stanzas[0].type, "scrypt")
        XCTAssertEqual(header.stanzas[0].args[1], "10")
        XCTAssertThrowsError(try Age.decrypt(ct, with: [ScryptIdentity(passphrase: "wrong")])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try Age.decrypt(ct, with: [ScryptIdentity(passphrase: "correct horse battery staple", maxWorkFactor: 9)])) {
            XCTAssertEqual($0 as? AgeError, .scryptWorkFactor)
        }
    }

    func testScryptMustBeAlone() {
        XCTAssertThrowsError(
            try Age.encrypt(Data(), to: [ScryptRecipient(passphrase: "a", workFactor: 2), X25519Identity().recipient])
        ) { XCTAssertEqual($0 as? AgeError, .scryptNotAlone) }
        XCTAssertThrowsError(try Age.encrypt(Data(), to: [ScryptRecipient(passphrase: "a", workFactor: 31)])) {
            XCTAssertEqual($0 as? AgeError, .scryptWorkFactor)
        }
    }

    func testMultipleRecipients() throws {
        let a = X25519Identity(), b = X25519Identity(), c = X25519Identity()
        let plaintext = random(1000)
        let ct = try Age.encrypt(plaintext, to: [a.recipient, b.recipient])
        XCTAssertEqual(try Age.parseHeader(ct).header.stanzas.count, 2)
        XCTAssertEqual(try Age.decrypt(ct, with: [a]), plaintext)
        XCTAssertEqual(try Age.decrypt(ct, with: [b]), plaintext)
        XCTAssertEqual(try Age.decrypt(ct, with: [c, b]), plaintext)
    }

    func testWrongIdentity() throws {
        let ct = try Age.encrypt(Data("hi".utf8), to: [X25519Identity().recipient])
        XCTAssertThrowsError(try Age.decrypt(ct, with: [X25519Identity()])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try Age.decrypt(ct, with: [ScryptIdentity(passphrase: "x")])) {
            XCTAssertEqual($0 as? AgeError, .noMatchingIdentity)
        }
        XCTAssertThrowsError(try Age.encrypt(Data(), to: [])) { XCTAssertEqual($0 as? AgeError, .noRecipients) }
    }

    func testTamperedPayload() throws {
        let id = X25519Identity()
        let plaintext = random(70_000)
        let ct = try Age.encrypt(plaintext, to: [id.recipient])
        let start = try Age.parseHeader(ct).payloadStart

        // Flip one byte in the second chunk: the first chunk is still released.
        var flipped = ct
        flipped[start + 16 + 65_536 + 16 + 10] ^= 1
        var released = Data()
        XCTAssertThrowsError(try Age.decrypt(binary: flipped, with: [id], released: &released)) {
            XCTAssertEqual($0 as? AgeError, .payload)
        }
        XCTAssertEqual(released, plaintext.prefix(65_536))

        // Truncate the final chunk.
        XCTAssertThrowsError(try Age.decrypt(ct.dropLast(1), with: [id])) { XCTAssertEqual($0 as? AgeError, .payload) }
        // Drop the final chunk entirely: the file ends after a non-final chunk.
        XCTAssertThrowsError(try Age.decrypt(ct.prefix(start + 16 + 65_536 + 16), with: [id])) {
            XCTAssertEqual($0 as? AgeError, .payload)
        }
        // Trailing data.
        XCTAssertThrowsError(try Age.decrypt(ct + Data([0]), with: [id])) { XCTAssertEqual($0 as? AgeError, .payload) }
        // Header tampering is caught by the MAC.
        var header = ct
        let (h, _) = try Age.parseHeader(ct)
        var stanzas = h.stanzas
        stanzas.append(Stanza(type: "grease", args: ["x"], body: Data()))
        let forged = Data(try HeaderCodec.encodeWithoutMAC(stanzas)) + Data(" \(Base64.encodeRaw(h.mac))\n".utf8)
            + ct.dropFirst(start)
        XCTAssertThrowsError(try Age.decrypt(forged, with: [id])) { XCTAssertEqual($0 as? AgeError, .headerMAC) }
        header[0] = UInt8(ascii: "b")
        XCTAssertThrowsError(try Age.decrypt(header, with: [id])) { XCTAssertEqual($0 as? AgeError, .headerParse) }
    }

    func testStanzaBodyWrapping() throws {
        // Bodies that are exact multiples of 48 bytes end with an empty line.
        for n in [0, 1, 47, 48, 49, 96, 100] {
            let s = Stanza(type: "test", args: ["a", "b"], body: random(n))
            let encoded = try HeaderCodec.encodeWithoutMAC([s]) + Array(" \(Base64.encodeRaw(Data(count: 32)))\n".utf8)
            let (h, start) = try Age.parseHeader(Data(encoded))
            XCTAssertEqual(h.stanzas, [s], "body \(n)")
            XCTAssertEqual(start, encoded.count)
            let lines = String(decoding: encoded, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertTrue(lines.allSatisfy { $0.utf8.count <= 64 || $0.hasPrefix("->") || $0.hasPrefix("---") })
        }
        XCTAssertThrowsError(try HeaderCodec.encodeStanza(Stanza(type: "a b", args: [], body: Data())))
        XCTAssertThrowsError(try HeaderCodec.encodeStanza(Stanza(type: "a", args: [""], body: Data())))
    }

    func testGreaseIsIgnored() throws {
        let id = X25519Identity()
        struct Grease: AgeRecipient {
            func wrap(fileKey: FileKey) throws -> [Stanza] {
                [Stanza(type: "example.com/grease", args: ["!x~"], body: Data(repeating: 7, count: 100))]
            }
        }
        let ct = try Age.encrypt(Data("ok".utf8), to: [Grease(), id.recipient])
        XCTAssertEqual(try Age.decrypt(ct, with: [id]), Data("ok".utf8))
    }

    func testArmorFormat() throws {
        let ct = try Age.encrypt(random(500), to: [X25519Identity().recipient], armor: true)
        let text = String(decoding: ct, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("-----BEGIN AGE ENCRYPTED FILE-----\n"))
        XCTAssertTrue(text.hasSuffix("\n-----END AGE ENCRYPTED FILE-----\n"))
        let body = text.split(separator: "\n").dropFirst().dropLast()
        XCTAssertTrue(body.dropLast().allSatisfy { $0.count == 64 })
        XCTAssertLessThanOrEqual(body.last?.count ?? 0, 64)
        // Exactly 48 * k bytes: no short line, footer straight after.
        XCTAssertEqual(
            String(decoding: Armor.encode(Data(count: 96)), as: UTF8.self).split(separator: "\n").count, 4)
        XCTAssertEqual(
            String(decoding: Armor.encode(Data()), as: UTF8.self),
            "-----BEGIN AGE ENCRYPTED FILE-----\n-----END AGE ENCRYPTED FILE-----\n")
    }

    func testBase64Strictness() {
        XCTAssertEqual(Base64.decodeRaw("AAAA".utf8), [0, 0, 0])
        XCTAssertNil(Base64.decodeRaw("AB".utf8))  // non-zero trailing bits
        XCTAssertNil(Base64.decodeRaw("AA==".utf8))  // padding
        XCTAssertNil(Base64.decodeRaw("A".utf8))
        XCTAssertNil(Base64.decodeRaw("AA\nA".utf8))
        XCTAssertEqual(Base64.decodePadded("AA==".utf8), [0])
        XCTAssertNil(Base64.decodePadded("AB==".utf8))
        XCTAssertNil(Base64.decodePadded("AA".utf8))
        XCTAssertNil(Base64.decodePadded("A===".utf8))
        XCTAssertNil(Base64.decodePadded("AA=A".utf8))
    }
}
