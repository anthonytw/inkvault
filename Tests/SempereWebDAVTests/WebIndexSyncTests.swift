import Foundation
import XCTest
@testable import Sempere
@testable import SempereWebDAV

/// `sync webdav` keeps a server-side `sempere-index.json` current
/// (docs/web-viewer.md "Hosting"): a viewer reading the share as static
/// files is never silently stale.
final class WebIndexSyncTests: SyncTestCase {
    func remoteIndex(_ server: MockDAV) throws -> [String: [String]]? {
        guard let data = server.file(WebIndex.fileName) else { return nil }
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["format"] as? String, WebIndex.format)
        return o["notes"] as? [String: [String]]
    }

    func testServerIndexFollowsEverySyncWhereItExists() throws {
        let server = MockDAV()
        let a = try makeVault()
        let first = try delta(a, device: devA, t: 0, title: "one")
        try sync("A", server)
        XCTAssertNil(server.file(WebIndex.fileName), "sync never creates the index")

        server.putDirect(WebIndex.fileName, Data("{\"format\":\"sempere-index/1\",\"notes\":{}}\n".utf8))
        let second = try delta(a, device: devA, t: 10, title: "two")
        let report = try sync("A", server)
        XCTAssertTrue(report.uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(try remoteIndex(server), [noteID.uuidString.lowercased(): [first.name.filename, second.name.filename]])
        // What the server holds is what the index lists.
        XCTAssertEqual(server.names(under: "notes/\(noteID.uuidString.lowercased())").sorted(),
                       [first.name.filename, second.name.filename])

        // Nothing changed: not rewritten.
        XCTAssertFalse(try sync("A", server).uploaded.contains(WebIndex.fileName))

        // A revision another device put on the server is listed too, and a dry run writes nothing.
        try sync("B", server)   // device B's first pull
        let fromB = try delta(try openVault("B"), device: devB, t: 20, title: "three")
        XCTAssertFalse(try sync("B", server, dryRun: true).uploaded.contains(WebIndex.fileName))
        XCTAssertEqual(try remoteIndex(server)?[noteID.uuidString.lowercased()]?.count, 2)
        try sync("B", server)
        XCTAssertEqual(try remoteIndex(server)?[noteID.uuidString.lowercased()],
                       [first.name.filename, second.name.filename, fromB.name.filename].sorted())
    }
}
