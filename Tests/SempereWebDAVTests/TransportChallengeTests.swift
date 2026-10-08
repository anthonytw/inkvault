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
        XCTAssertEqual(URLSessionTransport.disposition(forAuthenticationMethod: URLSessionTransport.serverTrustMethod),
                       .performDefaultHandling)
        #if !canImport(FoundationNetworking)
        XCTAssertEqual(URLSessionTransport.serverTrustMethod, NSURLAuthenticationMethodServerTrust)
        #endif
    }

    func testHTTPAuthenticationIsCancelled() {
        for m in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault] {
            XCTAssertEqual(URLSessionTransport.disposition(forAuthenticationMethod: m), .cancelAuthenticationChallenge, m)
        }
    }
}
