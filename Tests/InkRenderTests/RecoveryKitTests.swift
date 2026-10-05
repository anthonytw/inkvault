import Foundation
import InkVault
import XCTest
@testable import InkRender

final class RecoveryKitTests: XCTestCase {
    // The throwaway fixture key (Tests/InkVaultTests/Fixtures/sample.key).
    static let key = "AGE-SECRET-KEY-1JQ4L7CGCHC2TE7JUJ7YG4Y4DREUWFD7Y6U5XKFZ3EYTNY62Z5PES6MWJVN"
    static let recipient = "age1f406y9syjcsa2gj2lgz0s2g7suxrytycqr79zccg3d4spcujegqsgl00rd"
    static let armored = """
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCBtc2F2amlUZWhESW94cmlq
        OUhHVkFnIDE1CmpyQVlwUnZmaEQvcmk4d1puVzkzT2ovOXRjQWVzUUlrc1gvc0ls
        -----END AGE ENCRYPTED FILE-----

        """

    private func kit(_ secret: RecoveryKit.Secret, vault: Bool = true) -> RecoveryKit {
        RecoveryKit(secret: secret, recipient: Self.recipient,
                    vault: vault ? .init(name: "School", id: "5a3b1e00-1000-4000-8000-000000000001",
                                         created: Date(timeIntervalSince1970: 1_790_000_000), recipientCount: 2) : nil,
                    printed: Date(timeIntervalSince1970: 1_791_000_000))
    }

    /// The uncompressed content streams of our own PDF.
    private func streams(_ pdf: Data) -> [String] {
        let text = String(decoding: pdf, as: UTF8.self)
        var out: [String] = []
        var rest = Substring(text)
        while let s = rest.range(of: "stream\n"), let e = rest.range(of: "\nendstream", range: s.upperBound..<rest.endIndex) {
            out.append(String(rest[s.upperBound..<e.lowerBound]))
            rest = rest[e.upperBound...]
        }
        return out
    }

    /// Every `(...) Tj` string, unescaped.
    private func texts(_ stream: String) -> [String] {
        var out: [String] = []
        for line in stream.split(separator: "\n") where line.hasSuffix(") Tj") && line.hasPrefix("(") {
            var s = ""
            var escaped = false
            for c in line.dropFirst().dropLast(4) {
                if escaped { s.append(c); escaped = false } else if c == "\\" { escaped = true } else { s.append(c) }
            }
            out.append(s)
        }
        return out
    }

    /// Rebuilds the QR module grid from the run rectangles on the page.
    private func qrModules(_ stream: String, size: Int) throws -> [Bool] {
        var rects: [(Double, Double, Double, Double)] = []
        for line in stream.split(separator: "\n") where line.hasSuffix(" re") {
            let n = line.split(separator: " ").dropLast().compactMap { Double($0) }
            XCTAssertEqual(n.count, 4)
            rects.append((n[0], n[1], n[2], n[3]))
        }
        let m = try XCTUnwrap(rects.first?.3)
        let left = try XCTUnwrap(rects.map(\.0).min())
        let top = try XCTUnwrap(rects.map { $0.1 + $0.3 }.max())
        var grid = [Bool](repeating: false, count: size * size)
        for r in rects {
            XCTAssertEqual(r.3, m, accuracy: 0.002, "every run is one module high")
            let col = Int(((r.0 - left) / m).rounded())
            let row = Int(((top - r.1 - r.3) / m).rounded())
            let len = Int((r.2 / m).rounded())
            for c in col..<(col + len) { grid[row * size + c] = true }
        }
        return grid
    }

    func testPlainKitHoldsQRAndCheckedText() throws {
        let k = kit(.identity(Self.key))
        let pdf = try k.pdf()
        XCTAssertTrue(pdf.starts(with: Data("%PDF-1.4".utf8)))
        XCTAssertEqual(String(decoding: pdf, as: UTF8.self).components(separatedBy: "/Type /Page ").count - 1, 2)
        let pages = streams(pdf)
        XCTAssertEqual(pages.count, 2)
        let one = texts(pages[0]), two = texts(pages[1])

        // The warning, the vault, the public key.
        XCTAssertTrue(one.contains("THIS SHEET IS YOUR KEY."))
        XCTAssertTrue(one.contains("Vault:      School"))
        XCTAssertTrue(one.contains("Vault id:   5a3b1e00-1000-4000-8000-000000000001"))
        XCTAssertTrue(one.contains("Public key: \(Self.recipient)"))
        XCTAssertTrue(one.contains("Printed:    2026-10-03"))

        // The key in checked lines that join back to the key.
        let lines = PaperKey.identityLines(Self.key)
        XCTAssertEqual(lines.map(\.text).joined(), Self.key)
        for l in lines {
            XCTAssertTrue(one.contains(l.groups.joined(separator: " ")), l.text)
            XCTAssertTrue(one.contains(l.checksum), l.checksum)
        }
        XCTAssertTrue(one.contains { $0.contains("Bech32") })

        // The QR code on the page is exactly the encoder's symbol for the key.
        let code = try k.qrCode()
        XCTAssertEqual(code.errorCorrection, .quartile)
        XCTAssertEqual(code, try QRCode.encode(text: Self.key, correction: .quartile))
        XCTAssertEqual(try qrModules(pages[0], size: code.size), code.modules)

        // Recovery steps with stock tools match docs/format.md framing.
        XCTAssertTrue(two.contains { $0.contains("age -d -i key.txt FILE.age | tail -c +38 | gunzip | jq .") })
        XCTAssertTrue(two.contains { $0.contains("inkvault restore BACKUP_DIR") })
        XCTAssertTrue(two.contains { $0.contains("age-keygen -y key.txt") })
    }

    func testPassphraseKitNeverHoldsAPlainKey() throws {
        let k = kit(.passphraseWrapped(Self.armored), vault: false)
        let pdf = try k.pdf()
        let text = String(decoding: pdf, as: UTF8.self)
        XCTAssertFalse(text.contains("AGE-SECRET-KEY"))
        let one = texts(streams(pdf)[0])
        XCTAssertTrue(one.contains("THIS SHEET IS YOUR KEY, LOCKED WITH YOUR PASSPHRASE."))
        XCTAssertTrue(one.contains { $0.contains("(not given") })
        for l in PaperKey.textLines(Self.armored) {
            XCTAssertTrue(one.contains(l.text))
            XCTAssertTrue(one.contains(l.checksum))
        }
        XCTAssertEqual(PaperKey.textLines(Self.armored).count, 4)
        let code = try k.qrCode()
        XCTAssertEqual(code.errorCorrection, .medium)
        XCTAssertEqual(try qrModules(streams(pdf)[0], size: code.size), code.modules)
        XCTAssertTrue(texts(streams(pdf)[1]).contains { $0.contains("age -d -o key.txt key.age") })
    }

    func testA4AndLongWrappedFileStayOnThePage() throws {
        var k = kit(.passphraseWrapped("-----BEGIN AGE ENCRYPTED FILE-----\n"
            + String(repeating: String(repeating: "A", count: 64) + "\n", count: 9)
            + "-----END AGE ENCRYPTED FILE-----\n"))
        k.pageWidth = 595.28
        k.pageHeight = 841.89
        for stream in streams(try k.pdf()) {
            for line in stream.split(separator: "\n") where line.hasSuffix(" Td") {
                let n = line.split(separator: " ").compactMap { Double($0) }
                XCTAssertGreaterThan(n[1], 36, "text above the bottom margin: \(line)")
                XCTAssertLessThan(n[0], 595.28 - 54)
            }
        }
    }

    func testDocumentWriterBasics() throws {
        var page = PDFPage(width: 200, height: 100)
        page.text("a (b) \\ é", x: 10, y: 20, size: 12, font: .courier)
        page.fillRect(x: 0, y: 0, width: 10, height: 10)
        let pdf = try PDFDocument.render(pages: [page], title: "T")
        let s = String(decoding: pdf, as: UTF8.self)
        XCTAssertTrue(s.contains("(a \\(b\\) \\\\ ?) Tj"))
        XCTAssertTrue(s.contains("/BaseFont /Courier /Encoding /WinAnsiEncoding"))
        XCTAssertTrue(s.contains("10 80 Td"), "y is flipped to PDF's bottom-left origin")
        XCTAssertTrue(s.contains("0 90 10 10 re f"))
        XCTAssertFalse(s.contains("Helvetica"), "only fonts in use are declared")
        XCTAssertEqual(PDFPage.monospacedWidth("abcd", size: 10), 24)
        XCTAssertNil(PDFPage.monospacedWidth("abcd", size: 10, font: .helvetica))
        let compressed = try PDFDocument.render(pages: [page], compress: true)
        XCTAssertTrue(String(decoding: compressed, as: UTF8.self).contains("/FlateDecode"))
    }

    /// Rasterises the kit with poppler and decodes the QR code with zbar,
    /// where both are installed (apt install poppler-utils zbar-tools).
    func testPrintedQRDecodesWithZbar() throws {
        guard let pdftoppm = ["/usr/bin/pdftoppm", "/opt/homebrew/bin/pdftoppm"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
            try QRCodeTests.zbar(QRCodeTests.png(try QRCode.encode(text: "probe"))) != nil else {
            throw XCTSkip("pdftoppm or zbarimg not installed")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, secret, payload) in [("plain", RecoveryKit.Secret.identity(Self.key), Self.key),
                                        ("locked", .passphraseWrapped(Self.armored), Self.armored)] {
            try kit(secret).pdf().write(to: dir.appendingPathComponent("\(name).pdf"))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pdftoppm)
            p.arguments = ["-r", "150", "-f", "1", "-l", "1", "-png", "-singlefile",
                           dir.appendingPathComponent("\(name).pdf").path, dir.appendingPathComponent(name).path]
            try p.run()
            p.waitUntilExit()
            let png = try Data(contentsOf: dir.appendingPathComponent("\(name).png"))
            XCTAssertEqual(String(decoding: try XCTUnwrap(try QRCodeTests.zbar(png)), as: UTF8.self), payload, name)
        }
    }
}
