import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request, independent of the networking stack.
public struct WebDAVRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

/// One HTTP response. Header names are lowercased.
public struct WebDAVResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

/// Sends one request and returns the response, whatever its status. Throws
/// only when no response arrived (DNS, TLS, timeout, ...). Tests substitute
/// an in-memory server for this.
public protocol WebDAVTransport: Sendable {
    func send(_ request: WebDAVRequest) throws -> WebDAVResponse
}

/// The `URLSession` transport. Redirects are never followed: a redirect would
/// resend credentials and rewrite methods, so it surfaces as a 3xx response
/// that the client reports with the target.
public final class URLSessionTransport: WebDAVTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate = NoRedirects()

    public init(timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: WebDAVRequest) throws -> WebDAVResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: r) { data, response, error in
            box.set(data: data, response: response, error: error)
            done.signal()
        }
        task.resume()
        done.wait()
        let (data, response, error) = box.get()
        if let error { throw WebDAVError.transport(Self.describe(error)) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.transport("not an HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return WebDAVResponse(status: http.statusCode, headers: headers, body: data ?? Data())
    }

    private static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var response: URLResponse?
        private var error: Error?
        func set(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            self.data = data; self.response = response; self.error = error
        }
        func get() -> (Data?, URLResponse?, Error?) {
            lock.lock(); defer { lock.unlock() }
            return (data, response, error)
        }
    }
}
