import Foundation
import PencilKit
import SwiftUI
import Testing
import UIKit
@testable import SempereApp
import Sempere

/// The iPhone reader (`PhoneLayout.swift`): the stack navigation rules, the
/// reading mode of the canvas at iPhone sizes, and that the iPad keeps
/// drawing. Pure rules run on every destination; the view checks use the
/// destination's idiom, so the iPhone simulator run in CI exercises the phone
/// side and the iPad run the other.
struct CompactNavigationTests {
    @Test func poppingToTheListDropsTheNoteOnly() {
        #expect(CompactNavigation.clear(whenShowing: .content) == .init(note: true, sidebar: false))
    }

    @Test func poppingToTheSidebarDropsBothSelections() {
        #expect(CompactNavigation.clear(whenShowing: .sidebar) == .init(note: true, sidebar: true))
    }

    @Test func showingTheNoteDropsNothing() {
        #expect(CompactNavigation.clear(whenShowing: .detail) == .init())
    }

    @Test func aSelectedNoteOpensTheDetailColumn() {
        let id = UUID()
        #expect(CompactNavigation.column(note: id, sidebar: .allNotes, current: .sidebar) == .detail)
        #expect(CompactNavigation.column(note: id, sidebar: nil, current: .content) == .detail)
        #expect(CompactNavigation.column(note: id, sidebar: nil, current: .detail) == nil)   // already there
    }

    @Test func aSidebarSelectionOpensTheListOnlyFromTheSidebar() {
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .sidebar) == .content)
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .content) == nil)
        #expect(CompactNavigation.column(note: nil, sidebar: .tag("lecture"), current: .detail) == nil)
        #expect(CompactNavigation.column(note: nil, sidebar: nil, current: .sidebar) == nil)
    }

    /// Back, tap the same row again: the clear makes the second tap a change.
    @Test func theSameRowCanBeTappedAgainAfterABackSwipe() {
        var note: UUID? = UUID()
        var column = NavigationSplitViewColumn.detail
        let first = note
        column = .content
        if CompactNavigation.clear(whenShowing: column).note { note = nil }
        #expect(note == nil)
        note = first   // the list reports a selection change again
        #expect(CompactNavigation.column(note: note, sidebar: nil, current: column) == .detail)
    }
}

struct PhoneReadingTests {
    @Test func aPhoneReadsUntilAnnotationIsOn() {
        #expect(PhoneReading.drawingSuspended(isPhone: true, annotating: false))
        #expect(!PhoneReading.drawingSuspended(isPhone: true, annotating: true))
    }

    @Test func theIPadAndTheMacNeverSuspendDrawing() {
        #expect(!PhoneReading.drawingSuspended(isPhone: false, annotating: false))
        #expect(!PhoneReading.drawingSuspended(isPhone: false, annotating: true))
    }

    @Test func thePhonePaletteIsAlwaysTheShortOne() {
        #expect(PhoneReading.paletteCompact(isPhone: true, stored: false))
        #expect(!PhoneReading.paletteCompact(isPhone: false, stored: false))
        #expect(PhoneReading.paletteCompact(isPhone: false, stored: true))
    }

    @Test func annotationStartsOffForTheNextNote() {
        #expect(!PhoneReading.annotatingAfterNoteChange())
    }

    @Test func deviceNamesInTheKeyTexts() {
        #expect(RememberedKeys.name(isMac: false, isPhone: false) == "this iPad")
        #expect(RememberedKeys.name(isMac: false, isPhone: true) == "this iPhone")
        #expect(RememberedKeys.name(isMac: true, isPhone: false) == "this Mac")
    }
}

/// The canvas in windows of iPhone sizes (points): 6.9" Pro Max portrait, 6.3" portrait,
/// the small SE, and a landscape one.
@MainActor
@Suite(.serialized)
struct PhoneCanvasTests {
    static let sizes: [CGSize] = [CGSize(width: 440, height: 956), CGSize(width: 402, height: 874),
                                  CGSize(width: 375, height: 667), CGSize(width: 956, height: 440)]

    static func host(size: CGSize, pageSize: PageSize = PageSize(width: 612, height: 792, infinite: false, breakHeight: 792))
        -> (UIWindow, PageCanvasHost) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: pageSize)
        host.layoutIfNeeded()
        return (window, host)
    }

    @Test func thePageFitsTheWidthAtEveryPhoneSize() {
        for size in Self.sizes {
            let (window, host) = Self.host(size: size)
            #expect(abs(host.canvas.zoomScale - size.width / 612) < 0.0005, "\(size)")
            #expect(host.canvas.minimumZoomScale == host.canvas.zoomScale)
            #expect(abs(host.canvas.maximumZoomScale - host.canvas.minimumZoomScale * 4) < 0.0005)
            window.isHidden = true
        }
    }

    @Test func readingModeLeavesTheFingersToScrollAndZoom() {
        let (window, host) = Self.host(size: Self.sizes[0])
        host.drawingSuspended = true
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        #expect(host.canvas.isScrollEnabled)
        #expect(host.canvas.pinchGestureRecognizer?.isEnabled ?? true)
        #expect(host.canvas.panGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func annotatingTurnsFingerDrawingBackOn() {
        let (window, host) = Self.host(size: Self.sizes[1])
        host.drawingSuspended = true
        host.drawingSuspended = false
        #expect(host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func aReadOnlyNoteStaysUndrawableWhateverTheMode() {
        let (window, host) = Self.host(size: Self.sizes[2])
        host.isReadOnly = true
        host.drawingSuspended = false
        #expect(!host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func fingersDrawOnAPhoneAndTheIdiomMatchesTheDestination() {
        let (window, host) = Self.host(size: Self.sizes[0])
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        #expect(Platform.isPhone == phone)
        if phone { #expect(host.canvas.drawingPolicy == .anyInput) }
        window.isHidden = true
    }

    @Test func theIPadCanvasIsNotSuspendedByDefault() {
        let (window, host) = Self.host(size: CGSize(width: 1024, height: 1366))
        #expect(!host.drawingSuspended)
        #expect(host.canvas.drawingGestureRecognizer.isEnabled)
        window.isHidden = true
    }

    @Test func aFinitePageEndsWithRoomForTheFooterAtPhoneWidth() {
        let (window, host) = Self.host(size: Self.sizes[0])
        host.footer = .nextPage
        host.layoutIfNeeded()
        let z = host.canvas.zoomScale
        #expect(host.canvas.contentSize.height >= (792 * z) + PageExtent.footerScreenHeight - 0.5)
        #expect(!host.footerButton.isHidden)
        window.isHidden = true
    }
}

/// The root view hosted at an iPhone size: it must lay out without trapping,
/// on the welcome screen as well as with an unlocked vault.
@MainActor
@Suite(.serialized)
struct PhoneRootTests {
    @Test func theWelcomeScreenLaysOutAtPhoneWidth() {
        let model = AppModel()
        let controller = UIHostingController(rootView: RootView()
            .environment(model).environment(VaultLibrary(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathComponent("recents.json"))).environment(RememberedKeys(store: FakeKeyStore())))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()
        #expect(controller.view.bounds.width == 402)
        #expect(model.phase == .noVault)
        window.isHidden = true
    }
}
