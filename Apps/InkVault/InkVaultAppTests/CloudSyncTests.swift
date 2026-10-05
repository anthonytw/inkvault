import Foundation
import InkVault
import PencilKit
import Testing
import UIKit
@testable import InkVaultApp

/// iCloud Drive as iPadOS 26 presents it (dataless files under their real
/// names, folders listed before their contents), the sync progress model,
/// and the guarantees that a note is never shown or written from a partial
/// log.
@MainActor
struct CloudSyncTests {
    static let lecture = ProgressiveLoadTests.lecture
    static let other = ProgressiveLoadTests.other

    static func model(_ cloud: FakeCloud, stall: Duration = .seconds(5)) -> AppModel {
        let model = AppModel(deviceStateURL: TS.deviceStateURL())
        model.cloudHooks = cloud.hooks
        model.cloudPollInterval = .milliseconds(10)
        model.cloudIdleInterval = .milliseconds(20)
        model.cloudStallTimeout = stall
        return model
    }

    static func revisionCount(_ vault: URL, _ id: UUID) throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("notes/\(id.uuidString.lowercased())").path)
            .filter { $0.hasSuffix(".age") && !$0.hasPrefix(".") }.count
    }

    // MARK: - Root causes

    /// A note folder that lists no file is a note iCloud has not listed yet,
    /// never an empty note: it is pending and its folder is requested.
    @Test func anUnlistedNoteFolderIsPendingNotAnEmptyNote() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.other)
        let pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.ready == [Self.lecture])
        #expect(pass.pending == [Self.other])
        #expect(pass.unlisted == [Self.other])
        #expect(cloud.requestedFolders == [Self.other.uuidString.lowercased()])
        #expect(pass.files == pass.localFiles)
        #expect(pass.files > 0)
    }

    /// Dataless files keep their real names (no `.icloud` stand-in): they
    /// count as missing, and are not local.
    @Test func datalessRealNameFilesArePendingAndCounted() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        let pass = try ProgressiveLoad.pass(vault: url, hooks: cloud.hooks)
        #expect(pass.pending == [Self.lecture])
        #expect(pass.unlisted.isEmpty)
        let lectureFiles = try Self.revisionCount(url, Self.lecture)
        #expect(pass.localFiles == pass.files - lectureFiles)
        #expect(cloud.requestedNotes == [Self.lecture.uuidString.lowercased()])
    }

    @Test func requireLocalRefusesDatalessAndUnlistedNotes() throws {
        let (url, _) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try CloudVault.requireLocal(note: Self.lecture, vault: url, hooks: cloud.hooks)
        try cloud.evictDataless(Self.lecture)
        let n = try Self.revisionCount(url, Self.lecture)
        #expect(throws: CloudVault.CloudError.noteNotLocal(missing: n, total: n)) {
            try CloudVault.requireLocal(note: Self.lecture, vault: url, hooks: cloud.hooks)
        }
        try cloud.unlist(Self.other)
        #expect(throws: CloudVault.CloudError.noteNotLocal(missing: 0, total: 0)) {
            try CloudVault.requireLocal(note: Self.other, vault: url, hooks: cloud.hooks)
        }
        #expect(CloudVault.CloudError.noteNotLocal(missing: 0, total: 0).description.contains("not listed"))
    }

    /// The device bug: a note opened while iCloud had not listed its files
    /// came up as an empty, editable page. Now the canvas waits for them and
    /// shows the ink.
    @Test func openingAnUnlistedNoteWaitsForItsFilesAndShowsTheInk() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.lecture)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.placeholderNoteIDs.contains(Self.lecture))
        model.selectedNoteID = Self.lecture
        let showing = Task { await model.showSelectedNote() }
        #expect(await TS.waitUntil { cloud.requestedFolders.contains(Self.lecture.uuidString.lowercased()) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.editor == nil)                 // not opened as an empty note
        try cloud.deliver(Self.lecture)
        await showing.value
        let editor = try #require(model.editor)
        #expect(editor.pages.count == 2)
        #expect(editor.pages.flatMap(\.strokes).count > 0)
        #expect(model.editorFailure == nil)
        model.close()
    }

    /// Dataless real-name files are downloaded before the canvas reads them.
    @Test func openingADatalessNoteDownloadsItFirst() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        let showing = Task { await model.showSelectedNote() }
        #expect(await TS.waitUntil { model.noteDownload?.id == Self.lecture })
        #expect(model.noteDownload?.progress.total == (try Self.revisionCount(url, Self.lecture)))
        try cloud.deliver(Self.lecture)
        await showing.value
        #expect(model.editor?.pages.count == 2)
        #expect(model.editor?.isReadOnly == false)
        #expect(model.noteDownload == nil)
        model.close()
    }

    /// When the files never come, the detail pane says so (no blank canvas,
    /// no alert to miss) and nothing is written into the note.
    @Test func aNoteThatNeverArrivesShowsAFailureAndWritesNothing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.unlist(Self.lecture)
        let model = Self.model(cloud, stall: .milliseconds(150))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        model.selectedNoteID = Self.lecture
        await model.showSelectedNote()
        #expect(model.editor == nil)
        let failure = try #require(model.editorFailure)
        #expect(failure.id == Self.lecture)
        #expect(!failure.message.isEmpty)
        #expect(try Self.revisionCount(url, Self.lecture) == 0)
        // Retrying once the files are there opens it.
        try cloud.deliver(Self.lecture)
        await model.showSelectedNote()
        #expect(model.editorFailure == nil)
        #expect(model.editor?.pages.count == 2)
        model.close()
    }

    /// A file that goes missing between the download and the read (iCloud
    /// evicts it, another device adds one) is caught inside the read: the
    /// note is downloaded again instead of opening incomplete.
    @Test func theEditorReadRefusesAFileThatWentMissing() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        let clock = try model.deviceClockForWriting()
        let vault = try #require(try? Vault.open(at: url, identities: [IdentityFile.parse(String(contentsOf: key, encoding: .utf8))]))
        try cloud.evictDataless(Self.lecture)
        let hooks = cloud.hooks
        let id = Self.lecture
        await #expect(throws: CloudVault.CloudError.self) {
            _ = try await NoteEditor.open(vault: vault, noteID: id, clock: clock, coordinated: false,
                                          verify: { try CloudVault.requireLocal(note: id, vault: url, hooks: hooks) })
        }
        model.close()
    }

    // MARK: - Starting automatically

    /// Downloads start as soon as the vault is opened, before the key is
    /// entered, and the list fills after unlocking without a pull to refresh.
    @Test func syncStartsWhenTheVaultOpensAndFillsTheListWithoutARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        try cloud.evictDataless(Self.lecture)
        try cloud.evictDataless(Self.other)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        #expect(model.phase == .locked)
        #expect(await TS.waitUntil { model.cloudSync?.notes == 2 })
        #expect(model.cloudSync?.readyNotes == 0)
        #expect(model.cloudSync?.isDownloading == true)
        #expect(Set(cloud.requestedNotes) == Set([Self.lecture, Self.other].map { $0.uuidString.lowercased() }))
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        #expect(model.placeholderNoteIDs.count == 2)
        try cloud.deliver(Self.lecture)
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.placeholderNoteIDs.isEmpty && model.cloudSync?.isDownloading == false })
        #expect(model.notes.allSatisfy { !$0.title.isEmpty })
        model.close()
    }

    /// The loop never stops while the vault is open: a revision another
    /// device writes later arrives on its own.
    @Test func laterChangesArriveWithoutARefresh() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        try await Task.sleep(for: .milliseconds(200))           // settled, idling
        try cloud.evictDataless(Self.lecture)
        #expect(await TS.waitUntil { model.pendingNoteIDs.contains(Self.lecture) })
        #expect(model.cloudSync?.isDownloading == true)
        try cloud.deliver(Self.lecture)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty })
        model.close()
    }

    /// Reopening a vault (from recents, or later) syncs again by itself.
    @Test func reopeningAVaultSyncsAgainByItself() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let cloud = FakeCloud(vault: url)
        let model = Self.model(cloud)
        let text = try String(contentsOf: key, encoding: .utf8)
        try await model.openVault(at: url, identities: [IdentityFile.parse(text)])
        model.close()
        #expect(model.cloudSync == nil)
        try cloud.evictDataless(Self.other)
        try await model.openVault(at: url, identities: [IdentityFile.parse(text)])
        #expect(model.pendingNoteIDs == [Self.other])
        try cloud.deliver(Self.other)
        #expect(await TS.waitUntil { model.pendingNoteIDs.isEmpty && model.placeholderNoteIDs.isEmpty })
        #expect(model.notes.first { $0.id == Self.other }?.deleted == true)
        model.close()
    }

    // MARK: - Progress model

    @Test func syncStatusDescribesNotesAndFiles() {
        var s = CloudSyncStatus(notes: 128, readyNotes: 37, files: 277, localFiles: 80, unlistedNotes: 2)
        #expect(s.isDownloading)
        #expect(s.pendingNotes == 91)
        #expect(s.headline == "Downloading from iCloud: 37 of 128 notes")
        #expect(s.detail == "80 of 277 files, 2 note folders not listed yet")
        #expect(abs(s.fractionCompleted - 37.0 / 128) < 1e-9)
        s.readyNotes = 128
        #expect(!s.isDownloading)
        #expect(CloudSyncStatus().fractionCompleted == 1)
        #expect(CloudSyncStatus(notes: 1, readyNotes: 0, files: 1, localFiles: 0).headline == "Downloading from iCloud: 0 of 1 note")
        #expect(CloudSyncStatus(notes: 1, files: 1).detail == "0 of 1 file")
    }

    @Test func syncStatusFromAPass() {
        var pass = ProgressiveLoad.Pass()
        pass.all = [Self.lecture, Self.other]
        pass.ready = [Self.lecture]
        pass.pending = [Self.other]
        pass.unlisted = [Self.other]
        pass.files = 3
        pass.localFiles = 3
        let s = CloudSyncStatus(pass: pass)
        #expect(s == CloudSyncStatus(notes: 2, readyNotes: 1, files: 3, localFiles: 3, unlistedNotes: 1))
    }
}

/// How far a page scrolls, and when the screen stays on.
@MainActor
struct PageExtentTests {
    let infinite = PageSize(width: 612, height: 3473, infinite: true, breakHeight: 803.25)

    @Test func anInfinitePageScrollsAScreenBelowTheInk() {
        // Ink right at the stored bottom (an imported note): still a screen to go.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 3473, viewportHeight: 700) == 3473 + 700)
        // Ink below the stored height (just drawn, not yet grown).
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: 4000, viewportHeight: 700) == 4700)
        // No ink: the page plus a screen.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: nil, viewportHeight: 700) == 4173)
        // Bad values cannot shrink it.
        #expect(PageExtent.scrollHeight(pageSize: infinite, inkMaxY: .nan, viewportHeight: .infinity) == 3473)
    }

    @Test func anInfinitePageGrowsAsTheUserWrites() {
        var size = infinite
        let before = PageExtent.scrollHeight(pageSize: size, inkMaxY: 3473, viewportHeight: 700)
        size.height = 3473 + NoteEditor.growStep
        let after = PageExtent.scrollHeight(pageSize: size, inkMaxY: 3473 + 100, viewportHeight: 700)
        #expect(after > before)
        #expect(after - (3473 + 100) >= 700)
    }

    @Test func aFinitePageEndsWithRoomForItsFooter() {
        let letter = PageSize.letter
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: 700, viewportHeight: 500, footerHeight: 100)
                == letter.height + 100)
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 500) == letter.height)
        // Never less than a screen.
        #expect(PageExtent.scrollHeight(pageSize: letter, inkMaxY: nil, viewportHeight: 2000, footerHeight: 100) == 2000)
    }

    /// The canvas: a finite page shows its footer button below the page and
    /// scrolls far enough to reach it; an infinite one scrolls a screen past its ink.
    @Test func theCanvasHostUsesTheExtent() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
        defer { window.isHidden = true }
        let host = PageCanvasHost(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        host.apply(paper: .blank, pageSize: .letter)
        host.footer = .addPage
        host.layoutIfNeeded()
        let z = host.canvas.zoomScale
        #expect(!host.footerButton.isHidden)
        #expect(host.footerButton.configuration?.title == "Add Page")
        #expect(host.footerButton.frame.minY >= CGFloat(PageSize.letter.height) * z)
        #expect(host.canvas.contentSize.height >= host.footerButton.frame.maxY)
        var tapped = false
        host.footerAction = { tapped = true }
        host.footerButton.sendActions(for: .primaryActionTriggered)
        #expect(tapped)
        host.footer = .nextPage
        #expect(host.footerButton.configuration?.title == "Next Page")

        host.footer = .none
        host.canvas.drawing = PKDrawing(strokes: [StrokeConversion.pkStroke(TS.stroke(y: 1_900))])
        host.apply(paper: .blank, pageSize: PageSize(width: 612, height: 2_000, infinite: true, breakHeight: nil))
        host.inkDidChange()
        #expect(host.footerButton.isHidden)
        let ink = try #require(host.inkMaxY)
        let screen = Double(host.bounds.height / host.canvas.zoomScale)
        #expect(abs(Double(host.canvas.contentSize.height / host.canvas.zoomScale) - (max(2_000, ink) + screen)) < 1)
    }

    @Test func keepScreenOnOnlyWhileANoteIsOpenAndTheAppIsActive() {
        typealias K = KeepScreenOn
        #expect(K.idleTimerDisabled(enabled: true, noteOpen: true, active: true))
        #expect(!K.idleTimerDisabled(enabled: false, noteOpen: true, active: true))      // default off
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: false, active: true))      // note or vault closed
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: true, active: false))      // background
        #expect(K.idleTimerDisabled(enabled: false, noteOpen: false, active: true, debugLaunch: true))
        #expect(!K.idleTimerDisabled(enabled: true, noteOpen: true, active: false, debugLaunch: true))
    }
}
