import Foundation
import XCTest
@testable import SempereWebDAV
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Apple platforms deliver the TLS server-trust check to the task's challenge
/// handler; cancelling it failed every HTTPS sync with "cancelled".
final class TransportChallengeTests: XCTestCase {
    func testServerTrustIsLeftToTheSystem() {
        XCTAssertTrue(URLSessionTransport.isServerTrust(NSURLAuthenticationMethodServerTrust))
    }

    func testHTTPAuthenticationIsNotServerTrust() {
        for m in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
            XCTAssertFalse(URLSessionTransport.isServerTrust(m), m)
        }
    }
}
