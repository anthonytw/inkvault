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
    /// Largest response body accepted; a transport stops reading past it and
    /// throws `WebDAVError.responseTooLarge`. Nil means no limit.
    public var maxResponseBytes: Int?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                maxResponseBytes: Int? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
        self.maxResponseBytes = maxResponseBytes
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
/// that the client reports with the target. Bodies are read incrementally and
/// the request is cancelled once one exceeds `maxResponseBytes`, so a server
/// cannot make the client buffer more than that.
public final class URLSessionTransport: WebDAVTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate = Delegate()

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
        let task = session.dataTask(with: r)
        let pending = Pending(limit: request.maxResponseBytes)
        delegate.register(task.taskIdentifier, pending)
        defer { delegate.unregister(task.taskIdentifier) }
        task.resume()
        pending.done.wait()
        var (data, response, error, tooLarge, challenged) = pending.result()
        if tooLarge, let limit = request.maxResponseBytes {
            throw WebDAVError.responseTooLarge(path: request.url.path, limit: limit)
        }
        if error != nil, let challenged { response = challenged; error = nil }
        if let error { throw WebDAVError.transport(Self.describe(error)) }
        guard let http = (response ?? task.response) as? HTTPURLResponse else {
            throw WebDAVError.transport("not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
        return WebDAVResponse(status: http.statusCode, headers: headers, body: data)
    }

    private static func describe(_ error: Error) -> String {
        (error as NSError).localizedDescription
    }

    /// One request in flight: its body so far and how it ended.
    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let limit: Int?
        private let lock = NSLock()
        private var data = Data()
        private var response: URLResponse?
        private var error: Error?
        private var tooLarge = false
        private var challenged: HTTPURLResponse?

        init(limit: Int?) { self.limit = limit }

        /// False (and marks the request too large) when the body would exceed the limit.
        func accept(expected: Int64) -> Bool {
            guard let limit, expected > Int64(limit) else { return true }
            lock.lock(); tooLarge = true; lock.unlock()
            return false
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let limit, chunk.count > limit - data.count { tooLarge = true; return false }
            data.append(chunk)
            return true
        }

        func set(response r: URLResponse) { lock.lock(); response = r; lock.unlock() }
        func set(challenged r: HTTPURLResponse) { lock.lock(); challenged = r; lock.unlock() }
        func finish(_ e: Error?) { lock.lock(); error = e; lock.unlock(); done.signal() }

        func result() -> (Data, URLResponse?, Error?, Bool, HTTPURLResponse?) {
            lock.lock(); defer { lock.unlock() }
            return (data, response, error, tooLarge, challenged)
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(_ id: Int, _ p: Pending) { lock.lock(); pending[id] = p; lock.unlock() }
        func unregister(_ id: Int) { lock.lock(); pending[id] = nil; lock.unlock() }
        private func lookup(_ id: Int) -> Pending? { lock.lock(); defer { lock.unlock() }; return pending[id] }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        /// Credentials are sent preemptively in the header; a challenge is
        /// answered with the 401 itself, never with a stored credential.
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let r = challenge.failureResponse as? HTTPURLResponse { lookup(task.taskIdentifier)?.set(challenged: r) }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let p = lookup(dataTask.taskIdentifier) else { return completionHandler(.cancel) }
            p.set(response: response)
            completionHandler(p.accept(expected: response.expectedContentLength) ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let p = lookup(dataTask.taskIdentifier), p.append(data) else { return dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lookup(task.taskIdentifier)?.finish(error)
        }
    }
}
