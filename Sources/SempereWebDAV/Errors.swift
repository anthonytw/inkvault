import Foundation

/// Errors from the WebDAV layer. Messages never contain credentials.
public enum WebDAVError: Error, Hashable, Sendable {
    /// Plain `http` to anything but localhost, or credentials in the URL.
    case insecureURL(String)
    /// The server answered with an unexpected status.
    case http(method: String, path: String, status: Int)
    /// The server redirected; follow-ups are refused so credentials stay put.
    case redirect(path: String, location: String)
    /// No response (connection, TLS, timeout).
    case transport(String)
    /// The response could not be understood.
    case malformedResponse(String)
    /// The local vault and the remote one have different `vaultId`s.
    case vaultMismatch(local: String, remote: String)
    /// A local filesystem operation failed.
    case io(String)
    /// The response body exceeded the limit for this request; reading stopped there.
    case responseTooLarge(path: String, limit: Int)
    /// A bound of the whole run (`SyncLimits`) was reached; the run stopped
    /// there (security review 2026-10, W5).
    case limitExceeded(String)
}

extension WebDAVError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .insecureURL(let m): return m
        case .http(let method, let path, let status):
            let hint = (status == 401 || status == 403) ? " (check --user and the password)" : ""
            return "\(method) /\(path) failed: HTTP \(status)\(hint)"
        case .redirect(let path, let location):
            return "/\(SyncReport.printable(path)) redirects to \(SyncReport.printable(location)); "
                + "use that URL instead (redirects are not followed)"
        case .transport(let m): return "network error: \(m)"
        case .malformedResponse(let m): return "malformed server response: \(SyncReport.printable(m))"
        case .vaultMismatch(let l, let r):
            return "the remote holds vault \(r) but the local vault is \(l); refusing to mix them"
        case .io(let m): return m
        case .responseTooLarge(let path, let limit):
            return "the response for \(SyncReport.printable(path)) is over \(limit) bytes; not read"
        case .limitExceeded(let m): return "sync run stopped: \(m)"
        }
    }
}
