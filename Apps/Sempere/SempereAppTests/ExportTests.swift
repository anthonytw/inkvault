import Foundation
import Sempere
import SempereRender
import Testing
@testable import SempereApp

/// Share/export: what each format hands to the share sheet, the job around it
/// (progress, cancel, clean-up) and the commands' targets. The renderers
/// themselves are tested in SempereRenderTests (`ShareExportTests`).
@MainActor
final class ProgressRecorder {
    var seen: [ExportProgress] = []
}

@MainActor
struct ExportTests {
    static let lecture = AppModelTests.lecture
    static let deleted = AppModelTests.deleted
    static let lectureStem = "Fixture-lecture-11111111"

    func scratch() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
    }

    /// Paths of every file below `dir`, relative to it.
    func files(_ dir: URL) -> [String] {
        let base = dir.standardizedFileURL.path
        let walker = FileManager.default.enumerator(atPath: base)
        var out: [String] = []
        while let rel = walker?.nextObject() as? String {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + rel, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out.sorted()
    }

    func export(_ model: AppModel, _ ids: [UUID], _ options: ShareOptions, into dir: URL) async throws -> ShareResult {
        try await model.exportNotes(ids, options: options, into: dir) { _ in }
    }

    // MARK: Formats

    @Test func pdfOfOneNote() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try scratch()
        let r = try await export(model, [Self.lecture], ShareOptions(format: .pdf), into: dir)
        #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + ".pdf"])
        #expect(r.exported == 1 && r.failures.isEmpty)
        let data = try Data(contentsOf: r.items[0])
        #expect(data.prefix(5) == Data("%PDF-".utf8))
        #expect(data.count > 500)
    }

    @Test func pngPagesOfOneNote() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let r = try await export(model, [Self.lecture], ShareOptions(format: .png, dpi: 36), into: try scratch())
        // The fixture lecture has two pages.
        #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + "-p001.png", Self.lectureStem + "-p002.png"])
        for url in r.items {
            #expect(try Data(contentsOf: url).prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        }
    }

    @Test func markdownOfOneNoteIsAFolder() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let r = try await export(model, [Self.lecture], ShareOptions(format: .markdown), into: try scratch())
        #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem])
        let names = files(r.items[0])
        #expect(names.contains(Self.lectureStem + ".md"))
        #expect(names.contains(Self.lectureStem + ".pdf"))
        #expect(!names.contains { $0.hasPrefix(".") }, "no export manifest in a shared copy")
        let md = try String(contentsOf: r.items[0].appendingPathComponent(Self.lectureStem + ".md"), encoding: .utf8)
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("title: \"Fixture lecture\""))
        #expect(md.contains("sempere:\(model.vault?.vaultId.uuidString.lowercased() ?? "?")"))
    }

    @Test func htmlOfOneNoteIsOneSelfContainedFile() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try scratch()
        let r = try await export(model, [Self.lecture], ShareOptions(format: .html), into: dir)
        #expect(r.items.map(\.lastPathComponent) == [Self.lectureStem + ".html"])
        #expect(files(dir) == [Self.lectureStem + ".html"])
        let html = try String(contentsOf: r.items[0], encoding: .utf8)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<svg"))
        #expect(html.contains("Fixture lecture"))
        #expect(!html.contains("<script") && !html.contains("https://"))
    }

    @Test func severalNotesGiveTreesAndFolders() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let both = [Self.lecture, Self.deleted]
        let html = try await export(model, both, ShareOptions(format: .html), into: try scratch())
        #expect(html.items.map(\.lastPathComponent) == [ShareExport.treeFolderName])
        #expect(html.exported == 2)
        let htmlFiles = files(html.items[0])
        #expect(htmlFiles.contains("index.html"))
        #expect(htmlFiles.filter { $0.hasSuffix(".html") }.count == 3, "two notes and the index: \(htmlFiles)")

        let md = try await export(model, both, ShareOptions(format: .markdown), into: try scratch())
        #expect(md.items.map(\.lastPathComponent) == [ShareExport.treeFolderName])
        #expect(files(md.items[0]).filter { $0.hasSuffix(".pdf") }.count == 2)

        let merged = try await export(model, both, ShareOptions(format: .pdf, mergePDF: true), into: try scratch())
        #expect(merged.items.map(\.lastPathComponent) == [ShareExport.mergedPDFName])

        let separate = try await export(model, both, ShareOptions(format: .pdf), into: try scratch())
        #expect(separate.items.count == 2)

        let png = try await export(model, both, ShareOptions(format: .png, dpi: 36), into: try scratch())
        #expect(png.items.count == 2)
        #expect(png.items.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    @Test func aMissingNoteIsReportedAndTheRestExported() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let ghost = UUID()
        let r = try await export(model, [ghost, Self.lecture], ShareOptions(format: .pdf), into: try scratch())
        #expect(r.exported == 1)
        #expect(r.items.count == 1)
        #expect(r.failures.count == 1 && r.failures[0].hasPrefix(ghost.uuidString.lowercased()))
    }

    @Test func exportingNeedsAnUnlockedVault() async throws {
        let model = AppModel()
        await #expect(throws: AppModel.ModelError.noVaultOpen) {
            _ = try await model.exportNotes([Self.lecture], options: ShareOptions(format: .pdf), into: try self.scratch()) { _ in }
        }
    }

    @Test func exportDoesNotChangeTheVault() async throws {
        let (url, key) = try AppModelTests.fixtureVault()
        let model = AppModel(deviceStateURL: try BrowserTests.tempDir().appendingPathComponent("device.json"))
        try await model.openVault(at: url)
        try await model.unlock(identityText: try String(contentsOf: key, encoding: .utf8))
        func snapshot() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: files(url).map { ($0, (try? Data(contentsOf: url.appendingPathComponent($0)).count) ?? -1) })
        }
        let before = snapshot()
        for format in ShareFormat.allCases {
            _ = try await export(model, [Self.lecture], ShareOptions(format: format, dpi: 36), into: try scratch())
        }
        #expect(snapshot() == before)
    }

    // MARK: Cancel and progress

    @Test func cancellingBeforeTheFirstNoteWritesNothing() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try scratch()
        let task = Task { try await self.export(model, [Self.lecture, Self.deleted], ShareOptions(format: .pdf), into: dir) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func closingTheVaultStopsTheExport() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let dir = try scratch()
        let task = Task { try await self.export(model, [Self.lecture, Self.deleted], ShareOptions(format: .pdf), into: dir) }
        model.close()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }

    @Test func progressGrowsFromReadingToRendering() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let recorder = ProgressRecorder()
        let r = try await model.exportNotes([Self.lecture, Self.deleted], options: ShareOptions(format: .pdf), into: try scratch()) {
            recorder.seen.append($0)
        }
        let seen = recorder.seen
        #expect(r.exported == 2)
        #expect(seen.first?.phase == .reading && seen.first?.total == 2)
        #expect(seen.contains { $0.phase == .rendering })
        #expect(seen.allSatisfy { (0...1).contains($0.fraction) })
        #expect(ExportProgress(phase: .reading, done: 0, total: 4).fraction == 0)
        #expect(ExportProgress(phase: .rendering, done: 4, total: 4).fraction == 1)
        #expect(ExportProgress(phase: .rendering, done: 0, total: 0).fraction == 0)
    }

    // MARK: The job

    @Test func jobFinishesWithFilesAndDiscardDeletesThem() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let job = ExportJob()
        job.start(model: model, ids: [Self.lecture], options: ShareOptions(format: .pdf))
        let finished = await TS.waitUntil(timeout: .seconds(30)) { if case .finished = job.state { return true } else { return false } }
        #expect(finished)
        guard case .finished(let outcome) = job.state else { return }
        #expect(outcome.exported == 1)
        let file = try #require(outcome.items.first)
        #expect(file.path.hasPrefix(ExportJob.scratchRoot.standardizedFileURL.path) || file.path.contains("SempereExports"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        job.discard()
        #expect(job.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func jobCancelLeavesNothingBehind() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let job = ExportJob()
        job.start(model: model, ids: [Self.lecture, Self.deleted], options: ShareOptions(format: .png, dpi: 36))
        job.cancel()
        let settled = await TS.waitUntil(timeout: .seconds(30)) { !job.isRunning }
        #expect(settled)
        // Cancelled early: idle again. (If the run beat the cancel, it finished; either way it stopped.)
        if case .idle = job.state {} else if case .finished = job.state {} else { Issue.record("state \(job.state)") }
        job.discard()
        #expect(job.state == .idle)
    }

    @Test func jobFailsWhenNothingCouldBeExported() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        let job = ExportJob()
        job.start(model: model, ids: [UUID()], options: ShareOptions(format: .pdf))
        let done = await TS.waitUntil(timeout: .seconds(30)) { if case .failed = job.state { return true } else { return false } }
        #expect(done)
        job.discard()
    }

    @Test func purgeStaleRemovesStagedExports() throws {
        let stale = ExportJob.scratchRoot.appendingPathComponent("stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stale.appendingPathComponent("n.pdf"))
        ExportJob.purgeStale()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: Commands and targets

    @Test func commandsCoverEveryFormatOnce() {
        #expect(ExportCommand.allCases.map(\.format) == ShareFormat.allCases)
        #expect(Set(ExportCommand.allCases.map(\.title)).count == 4)
        #expect(Set(ExportCommand.allCases.map(\.systemImage)).count == 4)
    }

    @Test func requestsAndTargets() async throws {
        let model = try await BrowserTests.unlockedFixtureModel()
        #expect(model.exportTargetIDs.isEmpty)
        model.requestExport(.pdf, ids: [])
        #expect(model.exportRequest == nil, "nothing to export")

        model.selectedNoteID = Self.lecture
        #expect(model.exportTargetIDs == [Self.lecture])
        model.requestExport(.markdown, ids: model.exportTargetIDs)
        #expect(model.exportRequest?.noteIDs == [Self.lecture])
        #expect(model.exportRequest?.format == .markdown)

        model.isSelectingNotes = true
        model.multiSelection = [Self.lecture, Self.deleted, UUID()]
        // Only notes still in the vault, in list order (title sort).
        #expect(model.exportTargetIDs == [Self.deleted, Self.lecture])

        model.close()
        #expect(model.exportRequest == nil && model.multiSelection.isEmpty && !model.isSelectingNotes)
    }

    @Test func exportSheetDescribesTheShape() {
        for format in ShareFormat.allCases {
            for count in [1, 3] {
                #expect(!ExportSheet.shape(of: ShareOptions(format: format), count: count).isEmpty)
            }
        }
    }
}
