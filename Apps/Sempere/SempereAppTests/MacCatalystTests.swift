import Foundation
import Sempere
import SempereRender
import Testing
import UIKit
@testable import SempereApp

/// The Mac fixes from TestFlight build 6 (docs/mac.md "Fixed after build 6").
/// These run on the iPad simulator in every `app` job and on Mac Catalyst in
/// `scripts/app.sh test-mac` (CI on `main` and on dispatch), where the bugs
/// showed: a PDF page item must reach the screen, a dragged note must hand
/// out its PDF file.
@MainActor
struct MacCatalystPDFTests {
    /// A one-page PDF note in the fixture vault, through the import the app uses.
    static func pdfNote() async throws -> (AppModel, UUID, NoteState) {
        let model = try await BrowserTests.unlockedFixtureModel()
        let vault = try #require(model.vault)
        let url = try PDFImportTests.makePDF(pages: 1)
        guard case .done(let id) = await model.importPDF(copy: url, to: .newNote(notebook: nil), password: nil) else {
            Issue.record("not imported: \(model.errorMessage ?? "")")
            throw CancellationError()
        }
        return (model, id, try vault.reconstruct(noteId: id))
    }

    /// The blob cache can place files where it keeps them on this platform
    /// (file protection attributes, the sandboxed temporary directory).
    @Test func theBlobCacheWritesItsFilesOnThisPlatform() async throws {
        let (model, id, state) = try await Self.pdfNote()
        let ref = try #require(state.pages.first?.items.first?.blob)
        let cache = try #require(model.attachmentCache())
        let url = try await cache.acquire(note: id, ref: ref)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(size?.int64Value == ref.size)
        #expect(PDFDocumentBox(url: url) != nil, "Core Graphics opens the cached PDF")
        await cache.release(note: id, ref: ref)
    }

    /// The whole display path: the item layer opens the PDF, shows the page
    /// in a tile layer, and Core Animation draws it (red square top-left).
    @Test func aPDFPageReachesTheScreen() async throws {
        let (model, id, state) = try await Self.pdfNote()
        let page = try #require(state.pages.first)
        let item = try #require(page.items.first)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        let root = UIViewController()
        window.rootViewController = root
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        layer.backgroundColor = .white
        root.view.addSubview(layer)
        window.isHidden = false
        layer.setZoom(1)
        layer.show(page.items, note: id, paper: .blank, source: model.itemLayerSource)
        let tiled = await TS.waitUntil(timeout: .seconds(20)) { layer.tiledItemIDs.contains(item.id) }
        #expect(tiled, "the page is drawn in tiles; shown instead: \(String(describing: layer.picture(of: item.id)))")
        let tile = try #require(layer.tileLayer(of: item.id))
        // What a tile draws, in a y-down context (iOS) and a y-up one (a Mac layer's own).
        for flipped in [true, false] {
            let image = try #require(Self.draw(tile.content, size: CGSize(width: 612, height: 792), flipped: flipped))
            let p = try #require(ImageInsertTests.pixel(image, x: 20, y: 20))
            #expect(p.r > 200 && p.g < 80, "tile drawing (flipped \(flipped)): red at the top-left, got \(p)")
        }
        // What the window shows once Core Animation has drawn the tiles.
        var shown: (r: Int, g: Int, b: Int)?
        let drawn = await TS.waitUntil(timeout: .seconds(20)) {
            let renderer = UIGraphicsImageRenderer(bounds: layer.bounds)
            let image = renderer.image { _ in _ = layer.drawHierarchy(in: layer.bounds, afterScreenUpdates: true) }
            shown = image.cgImage.flatMap { ImageInsertTests.pixel($0, x: Int(20 * image.scale), y: Int(20 * image.scale)) }
            return shown.map { $0.r > 200 && $0.g < 80 } ?? false
        }
        #expect(drawn, "the window shows the page: \(String(describing: shown))")
        window.isHidden = true
    }

    /// Draws `content` the way a tile thread does, into a bitmap whose user
    /// space is y down (`flipped`) or y up, and returns it top row first.
    static func draw(_ content: PDFTileContent, size: CGSize, flipped: Bool) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if flipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        content.draw(in: ctx)
        return ctx.makeImage()
    }
}
