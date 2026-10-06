import Age
import Crypto
import Foundation
import XCTest
@testable import Sempere

/// The read side of the blob store (format.md §8.1.2–§8.1.4): names, framing,
/// verification, the previous-secret lookup during a rewrap, `BlobSource`.
final class BlobReadTests: VaultTestCase {
    /// The test vector of format.md §8.1.3.
    func testFormatVector() throws {
        let secret = try VaultSecret(bytes: Data((0..<32).map { UInt8($0) }))
        let content = Data("hello, sempere!\n".utf8)
        let ref = BlobRef(content: content, type: "text/plain")
        XCTAssertEqual(ref.sha256, "8ff2ca4079cee96a407a038a996ef5d0dd317f201fddc04174f0d89b763add65")
        XCTAssertEqual(ref.kind, .bin)
        XCTAssertEqual(Vault.blobName(sha256: try XCTUnwrap(ref.digest), secret: secret),
                       "13ddeae851cf51d7e9a970d82ca2c99f1dbaa3efaf792248da32b8374d6869af")
        let header = BlobFraming.header(sha256: try XCTUnwrap(ref.digest), length: 16)
        XCTAssertEqual(header.map { String(format: "%02x", $0) }.joined(),
                       "494e4b4201" + ref.sha256 + "0000000000000010")
        XCTAssertEqual(BlobFraming.padme(61), 64)
        XCTAssertEqual(BlobFraming.padme(1000), 1024)
        XCTAssertEqual(BlobFraming.padme(482_158), 483_328)
        XCTAssertEqual(BlobFraming.padme(28_311_597), 28_835_840)
        XCTAssertEqual(BlobFraming.padme(0), 0)
        XCTAssertEqual(BlobFraming.padme(1), 1)
        for n in [2, 3, 7, 8, 9, 100, 4097] { XCTAssertGreaterThanOrEqual(BlobFraming.padme(n), n) }
    }

    func testRoundTripThroughBlobSource() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })   // several age chunks
        let ref = try vault.writeBlobForTesting(note: note, content, type: "image/png")
        // Written once: a second write of the same content reuses the file.
        XCTAssertEqual(try vault.writeBlobForTesting(note: note, content, type: "image/png"), ref)
        let files = try FileManager.default.contentsOfDirectory(atPath: vault.attachmentsURL(note: note).path)
        XCTAssertEqual(files, ["\(try vault.blobName(sha256: XCTUnwrap(ref.digest))).image.age"])

        let reopened = try Vault.open(at: vault.url, identities: [id])
        let source = reopened.blobSource(note: note)
        XCTAssertEqual(try source.data(for: ref, maxBytes: 1 << 20), content)
        XCTAssertEqual(try source.withFile(for: ref) { try Data(contentsOf: $0) }, content)
        XCTAssertThrowsError(try source.data(for: ref, maxBytes: 1000)) {
            XCTAssertEqual($0 as? BlobError, .tooLarge(size: 200_000, limit: 1000))
        }
        // References resolve only inside their own note.
        XCTAssertThrowsError(try reopened.readBlob(note: UUID(), ref, maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? BlobError, .missing(sha256: ref.sha256))
        }
        // A reference with another length or type (kind) does not match.
        var shorter = ref
        shorter.size -= 1
        XCTAssertThrowsError(try reopened.readBlob(note: note, shorter, maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? BlobError, .invalid("header names other content"))
        }
        var pdf = ref
        pdf.type = "application/pdf"
        XCTAssertThrowsError(try reopened.readBlob(note: note, pdf, maxBytes: 1 << 20)) {
            XCTAssertEqual($0 as? BlobError, .missing(sha256: ref.sha256))
        }
        // Locked: no secret, no blobs.
        XCTAssertThrowsError(try Vault.open(at: vault.url).readBlob(note: note, ref, maxBytes: 1 << 20))
    }

    /// Hand-built files under the right name: every framing rule is checked.
    func testInvalidBlobsAreRefused() throws {
        let id = pqIdentity()
        let vault = try makeVault(id)
        let note = UUID()
        let content = Data("synthetic image bytes".utf8)
        let ref = BlobRef(content: content, type: "image/jpeg")
        let digest = try XCTUnwrap(ref.digest)
        let url = vault.attachmentsURL(note: note)
            .appendingPathComponent("\(try vault.blobName(sha256: digest)).image.age")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func plant(_ plain: Data) throws {
            try AgeFile.encrypt(plain, to: [id.recipient]).write(to: url)
        }
        let header = BlobFraming.header(sha256: digest, length: Int64(content.count))
        let cases: [(Data, BlobError)] = [
            (header + content + Data([0, 0, 1]), .invalid("non-zero padding")),
            (header + content.dropLast(), .invalid("content shorter than its length")),
            (header.prefix(20), .invalid("shorter than its header")),
            (Data("INKB".utf8) + Data([2]) + header.dropFirst(5) + content, .invalid("not a version-1 blob")),
            (BlobFraming.header(sha256: digest, length: Int64(content.count))
                + Data("synthetic image bytez".utf8), .invalid("content does not match its hash")),
        ]
        for (plain, error) in cases {
            try plant(plain)
            XCTAssertThrowsError(try vault.readBlob(note: note, ref, maxBytes: 1 << 20)) {
                XCTAssertEqual($0 as? BlobError, error)
            }
        }
        try plant(header + content + Data(count: 11))
        XCTAssertEqual(try vault.readBlob(note: note, ref, maxBytes: 1 << 20), content)
        // Not an age file at all.
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try vault.readBlob(note: note, ref, maxBytes: 1 << 20)) {
            guard case .unreadable = $0 as? BlobError else { return XCTFail("\($0)") }
        }
    }

    func testMemoryBlobSource() throws {
        let a = Data("a".utf8), b = Data("bb".utf8)
        let source = MemoryBlobSource([a, b])
        XCTAssertEqual(try source.data(for: BlobRef(content: b, type: "image/png"), maxBytes: 10), b)
        XCTAssertThrowsError(try source.data(for: BlobRef(content: Data("c".utf8), type: "image/png"), maxBytes: 10))
        var lying = BlobRef(content: a, type: "image/png")
        lying.size = 5
        XCTAssertThrowsError(try source.data(for: lying, maxBytes: 10))
    }
}
