import CoreGraphics
import Foundation
import Sempere
import Testing
import UIKit
@testable import SempereApp

/// Crash and robustness audit (no new features): each test pins a trap or
/// exception that data from a vault, a sync or the user could reach in the app.
@MainActor
struct RobustnessAuditTests {
    static let blob = BlobRef(content: Data("p".utf8), type: "application/pdf")

    /// A PDF page item whose frame decodes (positive size) but is huge: the
    /// preview's pixel size overflowed `Int(_:)` and trapped.
    @Test func aHugePDFPageFrameDrawsNoPreviewInsteadOfTrapping() throws {
        let url = try PDFImportTests.makePDF(pages: 1, size: CGSize(width: 200, height: 200))
        defer { PDFPreparation.discard(url) }
        let doc = try #require(PDFDocumentBox(url: url))
        for frame in [Rect(x: 0, y: 0, w: 1e150, h: 1e150), Rect(x: 0, y: 0, w: 1e300, h: 1e300),
                      Rect(x: 0, y: 0, w: .greatestFiniteMagnitude, h: 1)] {
            let item = Item.pdfPage(blob: Self.blob, pageIndex: 0, pageSize: Size(w: 200, h: 200), frame: frame, z: "a")
            let scale = RenderCache.previewScale(for: item, screenScale: 3)
            #expect(RenderCache.drawPreview(item, document: doc, scale: scale) == nil)
        }
        let normal = Item.pdfPage(blob: Self.blob, pageIndex: 0, pageSize: Size(w: 200, h: 200),
                                  frame: Rect(x: 0, y: 0, w: 100, h: 100), z: "a")
        #expect(RenderCache.drawPreview(normal, document: doc, scale: 2) != nil)
    }
}
