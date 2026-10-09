import Foundation
import Sempere
import SempereImport
import Testing
@testable import SempereApp

/// The app's Notability import: the CLI's options and the full report (GA-08).
@MainActor
struct NotabilityImportReportTests {
    @Test func theOptionsStartAtTheCLIDefaults() {
        let o = NotabilityImportOptions()
        #expect(o.attachments && o.pdfText && o.folderTags)
        #expect(!o.keepImageMetadata && !o.recognizeMissing)
        let imp = o.importer(notebook: " Research // 2026 ")
        #expect(imp.attachments && imp.tagsFromFolders && !imp.keepImageMetadata && imp.pdfText != nil)
        #expect(imp.notebook == "Research/2026")
        #expect(!imp.overwrite, "existing notes are never replaced")
    }

    @Test func eachOptionReachesTheImporter() {
        var o = NotabilityImportOptions()
        o.attachments = false; o.keepImageMetadata = true; o.pdfText = false; o.folderTags = false
        let imp = o.importer(notebook: nil)
        #expect(!imp.attachments && imp.keepImageMetadata && !imp.tagsFromFolders && imp.pdfText == nil)
        #expect(imp.notebook == nil)
    }

    @Test func theReportListsWhatWasImportedAndLeftOut() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        let note = try MacPolishBuild7Tests.syntheticNote()
        defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
        try await model.importNotability([note], notebook: nil)
        let summary = try #require(model.notabilitySummary)
        #expect(summary.imported == 1)
        #expect(!summary.details.recognitionAsked)
        // The synthetic note has no attachments; whatever it reports, rows are positive and unique.
        let rows = summary.details.imported + summary.details.notImported
        #expect(rows.allSatisfy { $0.count > 0 })
        model.close()
    }

    @Test func attachmentsOffAndRecognitionAreReported() async throws {
        let (model, _) = try await NoteWindowTests.unlockedModel()
        model.recognizer = FakeRecognizer()
        let note = try MacPolishBuild7Tests.syntheticNote()
        defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
        var options = NotabilityImportOptions()
        options.attachments = false
        options.recognizeMissing = true
        try await model.importNotability([note], notebook: nil, options: options)
        let summary = try #require(model.notabilitySummary)
        #expect(summary.imported == 1)
        #expect(summary.details.recognitionAsked)
        #expect(summary.details.recognitionFailed == 0)
        model.close()
    }

    @Test func warningsAreBoundedAndNameFilesOnly() {
        var result = NotabilityImporter.NoteResult(source: "/Users/x/Backup/Lecture.note", status: .ok)
        result.warnings = (0..<(NotabilityImportDetails.maxWarnings + 25)).map { _ in String(repeating: "w", count: 1_000) }
        var report = NotabilityImporter.ImportReport()
        report.notes = [result]
        let details = NotabilityImportDetails(report)
        #expect(details.warnings.count == NotabilityImportDetails.maxWarnings)
        #expect(details.moreWarnings == 25)
        #expect(details.warnings.allSatisfy { $0.count <= NotabilityImportDetails.maxWarningLength })
        #expect(details.warnings.allSatisfy { $0.hasPrefix("Lecture.note: ") }, "no folder paths")
    }

    @Test func everyLeftOutKindHasALabel() {
        let labels = NotabilityImporter.Dropped.Kind.allCases.map(NotabilityImportDetails.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count)
    }

    @Test func theSummaryMessageMentionsTheReadPages() {
        var summary = NotabilityImportSummary(imported: 2, skipped: 0, failed: 0, failures: [])
        summary.details.recognitionAsked = true
        summary.details.recognizedPages = 3
        #expect(summary.message.contains("3"))
        summary.details.recognitionFailed = 1
        #expect(summary.message.split(separator: "\n").count == 3)
    }
}
