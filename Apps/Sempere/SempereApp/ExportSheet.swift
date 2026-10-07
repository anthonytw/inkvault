import SempereRender
import SwiftUI
import UIKit

/// The export sheet: format and options, progress with Cancel, then Share and
/// Save to Files for the result.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest
    @State private var job = ExportJob()
    @State private var options: ShareOptions
    @State private var sharing = false
    @State private var saving = false

    init(request: ExportRequest) {
        self.request = request
        _options = State(initialValue: ShareOptions(format: request.format))
    }

    private static let resolutions: [Double] = [72, 144, 216, 300]

    var body: some View {
        NavigationStack {
            Form {
                switch job.state {
                case .idle:
                    settings
                case .running(let progress):
                    Section {
                        ProgressView(value: progress.fraction)
                        Text(progress.description).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Cancel Export", role: .destructive) { job.cancel() }
                    }
                case .finished(let outcome):
                    result(outcome)
                case .failed(let message):
                    Section {
                        Label("Export failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(message).font(.callout)
                    }
                    Section { Button("Try Again") { job.discard() } }
                }
            }
            .navigationTitle(Text("Export \(request.noteIDs.count) Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if job.isRunning { job.cancel() } else { dismiss() }
                    } label: {
                        if job.isRunning { Text("Stop", comment: "Button: stop a running export") } else { Text("Close") }
                    }
                }
            }
        }
        .interactiveDismissDisabled(job.isRunning)
        .onDisappear { job.discard() }
        .sheet(isPresented: $sharing) {
            if case .finished(let outcome) = job.state { ShareSheet(items: outcome.items) { sharing = false } }
        }
        .sheet(isPresented: $saving) {
            if case .finished(let outcome) = job.state { SaveToFiles(items: outcome.items) { saving = false } }
        }
    }

    @ViewBuilder
    private var settings: some View {
        Section("Format") {
            Picker("Format", selection: $options.format) {
                ForEach(ExportCommand.formats) { format in
                    Text(format.localizedTitle).tag(format)
                        .disabled(!model.canExport(format, ids: request.noteIDs))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section {
            Toggle("Paper Background and Ruling", isOn: $options.paper)
            if options.format == .png || (options.format == .markdown && options.markdownImages == .png) {
                Picker("Resolution", selection: $options.dpi) {
                    ForEach(Self.resolutions, id: \.self) { Text("\(Int($0)) dpi").tag($0) }
                }
            }
            if options.format == .pdf {
                // "PDF" and "PDF + attachments" side by side (docs/attachments.md §13 "Export options").
                Picker("PDF", selection: $options.pdfAttachments) {
                    Text("PDF").tag(false)
                    Text("PDF + attachments").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if options.format == .pdf && request.noteIDs.count > 1 {
                Toggle("One PDF for All Notes", isOn: $options.mergePDF)
            }
            if options.format == .markdown {
                Toggle("Include the PDF", isOn: $options.markdownPDF)
                Toggle("Add a PNG for Each Page", isOn: Binding(get: { options.markdownImages == .png },
                                                                set: { options.markdownImages = $0 ? .png : .none }))
            }
        } header: {
            Text("Options")
        } footer: {
            Text(verbatim: Self.shape(of: options, count: request.noteIDs.count)
                 + Self.recordingsNote(options, count: recordingCount))
        }
        Section {
            Button("Export", systemImage: ExportCommand.menuImage) {
                job.start(model: model, ids: request.noteIDs, options: options)
            }
        } footer: {
            Label("Exports are not encrypted. Anyone who receives the files can read the notes.", systemImage: "lock.open")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func result(_ outcome: ExportJob.Outcome) -> some View {
        Section {
            Label("\(outcome.exported) notes exported", systemImage: "checkmark.circle").foregroundStyle(.green)
            if outcome.recordingsAttached > 0 {
                Label("\(outcome.recordingsAttached) recordings attached", systemImage: "waveform")
            } else if outcome.recordingsOmitted > 0 {
                Label("\(outcome.recordingsOmitted) recordings not included", systemImage: "waveform.slash")
                    .foregroundStyle(.secondary)
            }
            ForEach(outcome.items, id: \.self) { Text($0.lastPathComponent).font(.callout) }
        }
        if !outcome.failures.isEmpty {
            Section("Not exported") {
                ForEach(outcome.failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
        }
        Section {
            Button("Share…", systemImage: "square.and.arrow.up") { sharing = true }
            Button("Save to Files…", systemImage: "folder") { saving = true }
        } footer: {
            Text("The files are deleted from the app when you close this sheet.")
        }
    }

    /// Recordings in the notes being exported (from their summaries).
    private var recordingCount: Int {
        let ids = Set(request.noteIDs)
        return model.notes.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.recordings }
    }

    /// " 2 recordings not included." for PDF, or what "PDF + attachments" adds.
    static func recordingsNote(_ options: ShareOptions, count: Int) -> String {
        guard count > 0 else { return "" }
        // A leading space: the sentence follows `shape(of:)` in the same footer.
        let sentence: String
        if options.format == .pdf && options.pdfAttachments {
            sentence = String(localized: "\(count) recordings and their transcripts attached to the PDF.")
        } else if options.format == .pdf {
            sentence = String(localized: "\(count) recordings not included (PDF + attachments includes them).")
        } else {
            sentence = String(localized: "\(count) recordings not included.", comment: "Export: recordings left out of the export")
        }
        return " " + sentence
    }

    /// One sentence on what the export will contain.
    static func shape(of options: ShareOptions, count: Int) -> String {
        let many = count > 1
        switch options.format {
        case .pdf:
            if many && options.mergePDF { return String(localized: "One PDF with every note.") }
            return many ? String(localized: "One PDF per note.") : String(localized: "A PDF with one page per note page.")
        case .png:
            return many ? String(localized: "A folder of PNG images per note.") : String(localized: "One PNG image per page.")
        case .markdown:
            if many {
                return options.markdownPDF
                    ? String(localized: "A folder tree like your notebooks, one Markdown file and PDF per note, with the recognised text.")
                    : String(localized: "A folder tree like your notebooks, one Markdown file per note, with the recognised text.")
            }
            if options.markdownPDF { return String(localized: "A folder with a Markdown file of the recognised text and PDF.") }
            return options.markdownImages != .none
                ? String(localized: "A folder with a Markdown file of the recognised text.")
                : String(localized: "A Markdown file with the recognised handwriting, page by page.")
        case .html:
            return many ? String(localized: "A folder with one self-contained HTML file per note and an index.")
                : String(localized: "One self-contained HTML file.")
        }
    }
}

extension ShareFormat {
    /// The format's name in the export sheet's picker (`title` is the library's English name).
    var localizedTitle: String {
        switch self {
        case .pdf: return String(localized: "PDF", comment: "Export format: PDF document")
        case .png: return String(localized: "PNG Pages", comment: "Export format: one PNG image per page")
        case .markdown: return String(localized: "Text (Markdown)", comment: "Export format: Markdown text")
        case .html: return String(localized: "HTML", comment: "Export format: HTML page")
        }
    }
}

/// The system share sheet (AirDrop, Messages, Mail, Save to Files, ...) for files and folders.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in done() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Save to Files": the document picker in export mode, copying `items` to the folder the user picks.
struct SaveToFiles: UIViewControllerRepresentable {
    let items: [URL]
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: items, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
    }
}
