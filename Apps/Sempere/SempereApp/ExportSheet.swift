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
            .navigationTitle(request.noteIDs.count == 1 ? "Export Note" : "Export \(request.noteIDs.count) Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(job.isRunning ? "Stop" : "Close") {
                        if job.isRunning { job.cancel() } else { dismiss() }
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
                    Text(format.title).tag(format)
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
            Text(Self.shape(of: options, count: request.noteIDs.count)
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
            Label(outcome.exported == 1 ? "1 note exported" : "\(outcome.exported) notes exported",
                  systemImage: "checkmark.circle").foregroundStyle(.green)
            if outcome.recordingsAttached > 0 {
                Label("\(outcome.recordingsAttached) recording\(outcome.recordingsAttached == 1 ? "" : "s") attached",
                      systemImage: "waveform")
            } else if outcome.recordingsOmitted > 0 {
                Label("\(outcome.recordingsOmitted) recording\(outcome.recordingsOmitted == 1 ? "" : "s") not included",
                      systemImage: "waveform.slash").foregroundStyle(.secondary)
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
        let n = count == 1 ? "1 recording" : "\(count) recordings"
        if options.format == .pdf && options.pdfAttachments {
            return " \(n) and \(count == 1 ? "its transcript" : "their transcripts") attached to the PDF."
        }
        return " \(n) not included\(options.format == .pdf ? " (PDF + attachments includes them)" : "")."
    }

    /// One sentence on what the export will contain.
    static func shape(of options: ShareOptions, count: Int) -> String {
        let many = count > 1
        switch options.format {
        case .pdf: return many && options.mergePDF ? "One PDF with every note." : many ? "One PDF per note." : "A PDF with one page per note page."
        case .png: return many ? "A folder of PNG images per note." : "One PNG image per page."
        case .markdown:
            let extra = options.markdownPDF ? " and PDF" : ""
            if many { return "A folder tree like your notebooks, one Markdown file\(extra) per note, with the recognised text." }
            return options.markdownPDF || options.markdownImages != .none
                ? "A folder with a Markdown file of the recognised text\(extra)."
                : "A Markdown file with the recognised handwriting, page by page."
        case .html: return many ? "A folder with one self-contained HTML file per note and an index."
            : "One self-contained HTML file."
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
