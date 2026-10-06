import Age
import Foundation
import XCTest
@testable import Sempere

/// Reading attachment blobs (format.md §8.1.2–§8.1.4).
final class BlobReadTests: VaultTestCase {
    func testNameAndPaddingVectors() throws {
        let secret = try VaultSecret(bytes: Data(0..<32))
        let content = Data("hello, sempere!\n".utf8)
        let ref = BlobRef(content: content, type: "text/plain")
        XCTAssertEqual(ref.sha256, "8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65")
        XCTAssertEqual(ref.kind, .bin)
        XCTAssertEqual(BlobFile.name(sha256: try XCTUnwrap(ref.digest), secret: secret),
                       "13ddeae851cf51d7e9a970d82ca2c99f1dbaa3efaf792248da32b8374d6869af")
        for (n, padded) in [(0, 0), (1, 1), (61, 64), (1000, 1024), (482_158, 483_328), (28_311_597, 28_835_840)] {
            XCTAssertEqual(BlobFile.padme(n), padded, "\(n)")
        }
        let plain = BlobFile.plaintext(content: content)
        XCTAssertEqual(plain.count, 64)
        XCTAssertEqual(plain.prefix(5), Data([0x49, 0x4E, 0x4B, 0x42, 0x01]))
        XCTAssertEqual(plain.subdata(in: 37..<45), Data([0, 0, 0, 0, 0, 0, 0, 0x10]))
    }

    func testRoundTrip() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })   // several age chunks
        let ref = try vault.writeBlob(note: note, content, type: "application/pdf")
        XCTAssertEqual(ref.kind, .pdf)
        let path = vault.url.appendingPathComponent("notes/\(note.uuidString.lowercased())/att/"
            + "\(try vault.blobName(sha256: try XCTUnwrap(ref.digest))).pdf.age")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try vault.readBlob(note: note, ref, maxBytes: 1 << 20), content)
        let source = vault.blobSource(note: note)
        var tempPath: URL?
        let viaFile = try source.withFile(for: ref) { url -> Data in
            tempPath = url
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(perms, 0o600)
            return try Data(contentsOf: url)
        }
        XCTAssertEqual(viaFile, content)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(tempPath).path))   // deleted after
        // A second note does not see the first one's blobs.
        XCTAssertThrowsError(try vault.readBlob(note: UUID(), ref, maxBytes: 1 << 20)) { e in
            guard case .missing? = e as? BlobError else { return XCTFail("\(e)") }
        }
    }

    func testLimitsAndBadReferences() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        let ref = try vault.writeBlob(note: note, Data(repeating: 7, count: 100), type: "image/png")
        XCTAssertThrowsError(try vault.readBlob(note: note, ref, maxBytes: 99)) { e in
            XCTAssertEqual(e as? BlobError, .tooLarge(size: 100, limit: 99))
        }
        var bad = ref
        bad.sha256 = "zz"
        XCTAssertThrowsError(try vault.readBlob(note: note, bad, maxBytes: 1000)) { e in
            XCTAssertEqual(e as? BlobError, .invalidReference)
        }
        // A reference whose size disagrees with the file's header.
        var wrongSize = ref
        wrongSize.size = 99
        XCTAssertThrowsError(try vault.readBlob(note: note, wrongSize, maxBytes: 1000)) { e in
            guard case .invalid? = e as? BlobError else { return XCTFail("\(e)") }
        }
    }

    /// A file stored under another content's name, a corrupted file, non-zero
    /// padding and a truncated file are all invalid, never returned.
    func testTamperedFilesAreRejected() throws {
        let vault = try makeVault(pqIdentity())
        let note = UUID()
        let a = try vault.writeBlob(note: note, Data("first".utf8), type: "application/pdf")
        let b = try vault.writeBlob(note: note, Data("second".utf8), type: "application/pdf")
        let urlA = try vault.blobURL(note: note, a), urlB = try vault.blobURL(note: note, b)
        func expectInvalid(_ ref: BlobRef, line: UInt = #line) {
            XCTAssertThrowsError(try vault.readBlob(note: note, ref, maxBytes: 1000), line: line) { e in
                guard case .invalid? = e as? BlobError else { return XCTFail("\(e)", line: line) }
            }
            XCTAssertThrowsError(try vault.withBlobFile(note: note, ref) { _ in XCTFail("body ran", line: line) },
                                 line: line)
        }
        try FileManager.default.removeItem(at: urlA)
        try FileManager.default.copyItem(at: urlB, to: urlA)
        expectInvalid(a)

        func store(_ plaintext: Data, as ref: BlobRef) throws {
            let url = try vault.blobURL(note: note, ref)
            try FileManager.default.removeItem(at: url)
            try Vault.encrypt(plaintext, to: try vault.ageRecipients()).write(to: url)
        }
        var padded = BlobFile.plaintext(content: Data("second".utf8))
        padded[padded.count - 1] = 1
        try store(padded, as: b)
        expectInvalid(b)
        try store(BlobFile.plaintext(content: Data("second".utf8)).prefix(48), as: b)
        expectInvalid(b)
        var flipped = BlobFile.plaintext(content: Data("second".utf8))
        flipped[45] ^= 1   // content no longer matches its hash
        try store(flipped, as: b)
        expectInvalid(b)
        try Data("not age".utf8).write(to: try vault.blobURL(note: note, b))
        expectInvalid(b)
    }

    func testLockedVaultCannotRead() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        let ref = try vault.writeBlob(note: note, Data("x".utf8), type: "application/pdf")
        let locked = try Vault.open(at: vault.url)
        XCTAssertThrowsError(try locked.readBlob(note: note, ref, maxBytes: 10)) { e in
            XCTAssertEqual(e as? VaultError, .locked)
        }
    }
}
