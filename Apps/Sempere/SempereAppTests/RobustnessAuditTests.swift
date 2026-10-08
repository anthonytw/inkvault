import CoreGraphics
import Foundation
import Sempere
import SempereRender
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

    /// An item whose frame overflows (corners NaN) or lies past the drawn
    /// extent is left out of the layer: Core Animation raises on a NaN
    /// position, which crashed the app every time the note was shown.
    @Test func itemsWhoseGeometryOverflowsAreNotShown() {
        var nan = AttachmentEditorTests.textItem("nan")
        nan.frame = Rect(x: 1.7e308, y: 0, w: 1.7e308, h: 10)
        var far = AttachmentEditorTests.textItem("far")
        far.frame = Rect(x: 0, y: 0, w: 1e20, h: 1)
        var spun = AttachmentEditorTests.textItem("spun")
        spun.rotation = 1e308
        let fine = AttachmentEditorTests.textItem("fine")
        let layer = ItemLayerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        layer.show([nan, far, spun, fine], note: UUID(), paper: .blank, source: ItemLayerSource(cache: nil))
        #expect(Set(layer.shownItemIDs) == [spun.id, fine.id])
        for sub in layer.layer.sublayers ?? [] {
            #expect(!sub.position.x.isNaN && !sub.position.y.isNaN)
            #expect(!sub.bounds.width.isNaN && !sub.bounds.height.isNaN)
            let t = sub.affineTransform()
            #expect([t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy(\.isFinite))
        }
    }

    /// The recording scrubber's range: `max(NaN, 0.1)` is NaN, and `0...NaN` traps.
    @Test func theScrubberRangeIsValidForAnyDuration() {
        #expect(RecordingClock.sliderRange(.nan) == 0...0.1)
        #expect(RecordingClock.sliderRange(.infinity) == 0...0.1)
        #expect(RecordingClock.sliderRange(-5) == 0...0.1)
        #expect(RecordingClock.sliderRange(0) == 0...0.1)
        #expect(RecordingClock.sliderRange(42) == 0...42)
    }

    /// A page size is not validated when decoded: a width of 0.001 asked
    /// PencilKit for a thumbnail bitmap of about 10^15 pixels.
    @Test func pageThumbnailInkHasAPixelBudget() {
        let normal = PageThumbnail.inkScale(page: CGSize(width: 612, height: 792), width: 120, scale: 2)
        #expect(abs(normal - 2 * 120 / 612) < 1e-9, "an ordinary page is drawn at the thumbnail's scale")
        for page in [CGSize(width: 0.001, height: 200_000), CGSize(width: 1, height: 200_000),
                     CGSize(width: 200_000, height: 200_000)] {
            let s = PageThumbnail.inkScale(page: page, width: 120, scale: 3)
            #expect(s.isFinite && s > 0)
            #expect(page.width * s * page.height * s <= PageThumbnail.maxInkPixels * 1.0001)
        }
        #expect(PageThumbnail.inkScale(page: CGSize(width: 0, height: 0), width: 120, scale: 2) == 1)
    }

    /// The video player's title clamps a huge stored duration (`Int(1e300)` trapped).
    @Test func aHugeVideoDurationTitles() {
        #expect(ExportVideos.clock(1e300) == "277777:46:40")
    }

    /// Opening or editing a note in iCloud lists its folder and asks each file's
    /// state (a file-system query per revision): off the main actor, never on it.
    @Test func downloadingANoteAsksFileStatesOffTheMainThread() async throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var armed = false, onMain = 0, offMain = 0
        }
        let calls = Calls()
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = CloudSyncTests.model(cloud)
        var hooks = cloud.hooks
        let state = hooks.state
        hooks.state = { item in
            calls.lock.withLock {
                if calls.armed { if Thread.isMainThread { calls.onMain += 1 } else { calls.offMain += 1 } }
            }
            return state(item)
        }
        model.cloudHooks = hooks
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let loop = model.cloudSyncTask
        model.pauseCloudSync()
        await loop?.value
        calls.lock.withLock { calls.armed = true }
        try await model.downloadNote(CloudSyncTests.lecture)
        calls.lock.withLock { calls.armed = false }
        #expect(calls.lock.withLock { calls.offMain } > 0)
        #expect(calls.lock.withLock { calls.onMain } == 0)
        model.close()
    }

    /// A drop's file request whose preparation never ends (the main-actor work
    /// cannot run while the system holds the main thread for the file) fails
    /// after the timeout instead of hanging the Mac app.
    @Test func aDragOutWhosePreparationNeverEndsFailsInsteadOfHanging() async throws {
        let never = Task<PreparedExport, any Error> {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        let start = ContinuousClock.now
        let error: (any Error)? = await withCheckedContinuation { c in
            NoteFileDrag.load(never, timeout: .milliseconds(200)) { url, error in
                c.resume(returning: url == nil ? error : nil)
            }
        }
        #expect(error is NoteFileDrag.DragError)
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(never.isCancelled, "the preparation is given up too")
    }
}
