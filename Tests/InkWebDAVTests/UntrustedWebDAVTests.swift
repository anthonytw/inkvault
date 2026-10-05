import Foundation
import XCTest

@testable import InkWebDAV

/// Regression tests for hostile WebDAV responses (see `WebDAVFuzzTests`).
final class UntrustedWebDAVTests: XCTestCase {
    func assertMalformed(_ body: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PropfindParser.parse(body), file: file, line: line) { e in
            guard case WebDAVError.malformedResponse? = e as? WebDAVError else {
                return XCTFail("\(e)", file: file, line: line)
            }
        }
    }

    /// An element name with an invalid UTF-8 byte after the root element
    /// trapped inside FoundationXML's XMLParser on Linux (found by fuzzing a
    /// PROPFIND response). Such bodies are now refused before parsing.
    func testInvalidUTF8ElementNameIsRefusedNotTrapped() {
        assertMalformed(Data([0x3C, 0x61, 0x3E, 0x3C, 0x62, 0xC3, 0x2F, 0x3E, 0x3C, 0x2F, 0x61, 0x3E]))  // <a><b\xC3/></a>
        assertMalformed(Data(#"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/x"#.utf8) + Data([0xFF])
                        + Data("</d:href></d:response></d:multistatus>".utf8))
    }

    /// Entity declarations (billion laughs, external entities) are refused
    /// outright: a multistatus never needs a DTD.
    func testDTDIsRefused() {
        assertMalformed(Data(#"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY a "aaaa">]><d:multistatus xmlns:d="DAV:"/>"#.utf8))
    }

    func testOrdinaryMultistatusStillParses() throws {
        let body = #"<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:"><d:response>"#
            + "<d:href>/dav/vault/caf%C3%A9/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/>"
            + "</d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>"
        let items = try PropfindParser.parse(Data(body.utf8))
        XCTAssertEqual(items.map(\.href), ["/dav/vault/caf%C3%A9/"])
        XCTAssertEqual(items.first?.isCollection, true)
    }
}
