import Foundation
import SempereWebDAV

/// An in-memory WebDAV server: PROPFIND (Depth 0/1), GET, PUT with
/// If-Match / If-None-Match, MKCOL, DELETE. Just enough for the sync.
final class MockDAV: WebDAVTransport, @unchecked Sendable {
    struct Stored { var data: Data; var etag: String }
    private let lock = NSLock()
    private var files: [String: Stored] = [:]
    private var collections: Set<String>

    init(collections: Set<String> = ["", "/dav", "/dav/vault"]) { self.collections = collections }
    private var counter = 0
    private(set) var requests: [(method: String, path: String)] = []
    /// When set, called for each request; return a response to short-circuit.
    var interceptor: (@Sendable (WebDAVRequest) -> WebDAVResponse?)?
    /// Expected `Authorization` header, if any.
    var requiredAuthorization: String?

    static let base = "/dav/vault"

    func file(_ rel: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[Self.base + "/" + rel]?.data }
    func putDirect(_ rel: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        collect(parentOf: Self.base + "/" + rel)
        counter += 1
        files[Self.base + "/" + rel] = Stored(data: data, etag: "\"e\(counter)\"")
    }
    func removeDirect(_ rel: String) { lock.lock(); files[Self.base + "/" + rel] = nil; lock.unlock() }
    func names(under rel: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let p = Self.base + "/" + rel + "/"
        return files.keys.filter { $0.hasPrefix(p) }.map { String($0.dropFirst(p.count)) }.sorted()
    }
    var requestLog: [(method: String, path: String)] { lock.lock(); defer { lock.unlock() }; return requests }

    private func collect(parentOf path: String) {
        var p = path
        while let i = p.lastIndex(of: "/"), i != p.startIndex {
            p = String(p[..<i]); collections.insert(p)
        }
    }

    func send(_ r: WebDAVRequest) throws -> WebDAVResponse {
        if let hit = interceptor?(r) { return hit }
        lock.lock(); defer { lock.unlock() }
        let path = (r.url.path.removingPercentEncoding ?? r.url.path)
        let key = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        requests.append((r.method, key))
        if let want = requiredAuthorization, r.headers["Authorization"] != want { return WebDAVResponse(status: 401) }
        switch r.method {
        case "PROPFIND":
            let depth = r.headers["Depth"] ?? "1"
            if collections.contains(key) {
                var xml = entry(key + "/", etag: nil, collection: true, size: nil)
                if depth == "1" {
                    var kids = Set<String>()
                    for c in collections where c != key && parent(c) == key { kids.insert(c) }
                    for c in kids.sorted() { xml += entry(c + "/", etag: nil, collection: true, size: nil) }
                    for (f, s) in files.sorted(by: { $0.key < $1.key }) where parent(f) == key {
                        xml += entry(f, etag: s.etag, collection: false, size: s.data.count)
                    }
                }
                return multistatus(xml)
            }
            if let s = files[key] { return multistatus(entry(key, etag: s.etag, collection: false, size: s.data.count)) }
            return WebDAVResponse(status: 404)
        case "GET":
            guard let s = files[key] else { return WebDAVResponse(status: 404) }
            return WebDAVResponse(status: 200, headers: ["ETag": s.etag], body: s.data)
        case "PUT":
            guard collections.contains(parent(key)) else { return WebDAVResponse(status: 409) }
            let existing = files[key]
            if r.headers["If-None-Match"] == "*", existing != nil { return WebDAVResponse(status: 412) }
            if let m = r.headers["If-Match"], existing?.etag != m { return WebDAVResponse(status: 412) }
            counter += 1
            files[key] = Stored(data: r.body ?? Data(), etag: "\"e\(counter)\"")
            return WebDAVResponse(status: existing == nil ? 201 : 204)
        case "MKCOL":
            if collections.contains(key) { return WebDAVResponse(status: 405) }
            guard collections.contains(parent(key)) else { return WebDAVResponse(status: 409) }
            collections.insert(key)
            return WebDAVResponse(status: 201)
        case "DELETE":
            return WebDAVResponse(status: files.removeValue(forKey: key) == nil ? 404 : 204)
        default:
            return WebDAVResponse(status: 405)
        }
    }

    private func parent(_ p: String) -> String { String(p[..<(p.lastIndex(of: "/") ?? p.startIndex)]) }

    private func entry(_ href: String, etag: String?, collection: Bool, size: Int?) -> String {
        let encoded = href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href
        var props = collection ? "<d:resourcetype><d:collection/></d:resourcetype>" : "<d:resourcetype/>"
        if let etag { props += "<d:getetag>\(etag.replacingOccurrences(of: "\"", with: "&quot;"))</d:getetag>" }
        if let size { props += "<d:getcontentlength>\(size)</d:getcontentlength>" }
        return "<d:response><d:href>\(encoded)</d:href><d:propstat><d:prop>\(props)</d:prop>"
            + "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }

    private func multistatus(_ body: String) -> WebDAVResponse {
        WebDAVResponse(status: 207, headers: ["Content-Type": "application/xml"],
                       body: Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(body)</d:multistatus>".utf8))
    }
}
