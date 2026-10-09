import CLITestSupport
import Foundation
import Sempere
import XCTest

final class CLIWebDAVTests: CLITestCase {
    func testRefusesPlainHTTPToARemoteHost() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "http://dav.example.com/vault/", "--vault", vault, "--dry-run"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("refusing plain http"), r.err)
    }

    func testUserNeedsItsPasswordVariable() throws {
        let vault = try copyFixtureVault()
        let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--user", "me",
                         "--password-env", "NOPE_NOT_SET"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("NOPE_NOT_SET"), r.err)
        XCTAssertFalse(r.err.contains("secret"))
        let lone = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--password-env", "X"])
        XCTAssertEqual(lone.status, 2, lone.err)
    }

    func testMaxBlobSizeIsValidated() throws {
        let vault = try copyFixtureVault()
        for bad in ["0", "-3", "1048577"] {
            let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--max-blob-mib", bad])
            XCTAssertEqual(r.status, 2, "\(bad): \(r.err)")
            XCTAssertTrue(r.err.contains("max-blob-mib") || r.err.contains("Missing value"), r.err)
        }
    }

    /// Security review 2026-10 (W5): the run bounds are validated.
    func testRunLimitsAreValidated() throws {
        let vault = try copyFixtureVault()
        for (flag, bad) in [("--max-notes", "0"), ("--max-entries", "-1"), ("--max-download-mib", "0"),
                            ("--max-minutes", "525601")] {
            let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, flag, bad])
            XCTAssertEqual(r.status, 2, "\(flag) \(bad): \(r.err)")
            XCTAssertTrue(r.err.contains(String(flag.dropFirst(2))) || r.err.contains("Missing value"), r.err)
        }
    }

    func testPushOnlyFlagRules() throws {
        let vault = try copyFixtureVault()
        let lone = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", vault, "--delete-extraneous"])
        XCTAssertEqual(lone.status, 2, lone.err)
        XCTAssertTrue(lone.err.contains("--push-only"), lone.err)
        // A mirror never creates the vault: no vault.json is a usage error before any request.
        let empty = path("empty.sempere")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let r = try cli(["sync", "webdav", "https://dav.example.com/v/", "--vault", empty, "--push-only"])
        XCTAssertEqual(r.status, 2, r.err)
        XCTAssertTrue(r.err.contains("--push-only needs an existing vault"), r.err)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: empty), [])
    }

    /// Needs a live server (scripts/test-webdav.sh): a mirror never changes the vault.
    func testPushOnlyAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-push-\(UUID().uuidString.lowercased())/vault/"
        let vault = try copyFixtureVault(as: "mirror.sempere")
        let e = ["TEST_DAV_PW": password]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW", "--push-only"]
        let manifest = URL(fileURLWithPath: vault).appendingPathComponent("vault.json")
        let before = try Data(contentsOf: manifest)

        let up = try cli(["sync", "webdav", url, "--vault", vault, "--json"] + common, env: e)
        XCTAssertEqual(up.status, 0, up.err)
        let json = try XCTUnwrap(up.json as? [String: Any])
        XCTAssertGreaterThan((json["uploaded"] as? [String])?.count ?? 0, 1)
        XCTAssertEqual(json["downloaded"] as? [String] ?? ["?"], [])
        XCTAssertEqual(json["extraneous"] as? [String] ?? ["?"], [])
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        let again = try cli(["sync", "webdav", url, "--vault", vault] + common, env: e)
        XCTAssertTrue(again.out.contains("0 uploaded, 0 downloaded, 0 deleted, 0 conflicts, 0 errors"), again.out)
    }

    /// Needs a live server: set by scripts/test-webdav.sh, skipped otherwise.
    func testSyncAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SEMPERE_WEBDAV_TEST_URL"], let user = env["SEMPERE_WEBDAV_TEST_USER"],
              let password = env["SEMPERE_WEBDAV_TEST_PASSWORD"] else { throw XCTSkip("no WebDAV test server") }
        let url = base + "cli-\(UUID().uuidString.lowercased())/vault/"
        let vault = try copyFixtureVault(as: "one.sempere")
        let e = ["TEST_DAV_PW": password]
        let common = ["--user", user, "--password-env", "TEST_DAV_PW"]

        let dry = try cli(["sync", "webdav", url, "--vault", vault, "--dry-run", "--json"] + common, env: e)
        XCTAssertEqual(dry.status, 0, dry.err)
        let dryJSON = try XCTUnwrap(dry.json as? [String: Any])
        XCTAssertEqual(dryJSON["dryRun"] as? Bool, true)
        let planned = (dryJSON["uploaded"] as? [String])?.count ?? 0
        XCTAssertGreaterThan(planned, 1)
        XCTAssertTrue((dryJSON["uploaded"] as? [String] ?? []).contains { $0.contains("/att/") }, "the fixture's blob syncs too")

        let up = try cli(["sync", "webdav", url, "--vault", vault, "--json"] + common, env: e)
        XCTAssertEqual(up.status, 0, up.err)
        XCTAssertEqual((up.json as? [String: Any])?["uploaded"] as? [String] ?? [], dryJSON["uploaded"] as? [String] ?? ["?"])

        let other = path("two.sempere")
        let down = try cli(["sync", "webdav", url, "--vault", other, "--json"] + common, env: e)
        XCTAssertEqual(down.status, 0, down.err)
        XCTAssertEqual(((down.json as? [String: Any])?["downloaded"] as? [String])?.count, planned)
        let a = try cli(["notes", "list", "--vault", vault, "--identity", Self.fixtureKey, "--json"])
        let b = try cli(["notes", "list", "--vault", other, "--identity", Self.fixtureKey, "--json"])
        XCTAssertEqual(a.status, 0, a.err)
        XCTAssertEqual(a.out, b.out)
        let verify = try cli(["vault", "verify", "--vault", other, "--identity", Self.fixtureKey])
        XCTAssertEqual(verify.status, 0, verify.out + verify.err)

        // Second run is a no-op and says so; text mode prints the summary line.
        let again = try cli(["sync", "webdav", url, "--vault", other] + common, env: e)
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertTrue(again.out.contains("0 uploaded, 0 downloaded, 0 deleted, 0 conflicts, 0 errors"), again.out)
        // Wrong password: exit 1 with a one-line error, never the password.
        let bad = try cli(["sync", "webdav", url, "--vault", other] + common, env: ["TEST_DAV_PW": "wrong-pw"])
        XCTAssertEqual(bad.status, 1, bad.err)
        XCTAssertTrue(bad.err.contains("401"), bad.err)
        XCTAssertFalse(bad.err.contains("wrong-pw"))
    }
}
