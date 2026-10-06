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
                ForEach(ShareFormat.allCases) { Text($0.title).tag($0) }
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
            if options.format == .pdf && request.noteIDs.count > 1 {
                Toggle("One PDF for All Notes", isOn: $options.mergePDF)
            }
            if options.format == .markdown {
                Toggle("Add a PNG for Each Page", isOn: Binding(get: { options.markdownImages == .png },
                                                                set: { options.markdownImages = $0 ? .png : .none }))
            }
        } header: {
            Text("Options")
        } footer: {
            Text(Self.shape(of: options, count: request.noteIDs.count))
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

    /// One sentence on what the export will contain.
    static func shape(of options: ShareOptions, count: Int) -> String {
        let many = count > 1
        switch options.format {
        case .pdf: return many && options.mergePDF ? "One PDF with every note." : many ? "One PDF per note." : "A PDF with one page per note page."
        case .png: return many ? "A folder of PNG images per note." : "One PNG image per page."
        case .markdown: return many ? "A folder tree like your notebooks, one Markdown file and PDF per note, for Obsidian."
            : "A folder with a Markdown file and the PDF, for Obsidian."
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
