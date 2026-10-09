import SwiftUI

/// What the file picker returned for "Import from Notability…", waiting for the options sheet.
struct NotabilityPick: Identifiable, Equatable {
    let id = UUID()
    var urls: [URL]
    /// The sidebar's notebook when the files were picked (nil: Notability's own folder or subject).
    var notebook: String?
}

/// The options of an import (the CLI's `import notability` flags, `NotabilityImportOptions`), asked after
/// the files are picked and before anything is written.
struct NotabilityImportOptionsSheet: View {
    @AppModelEnvironment private var model
    @Environment(\.dismiss) private var dismiss
    let pick: NotabilityPick
    @State private var options = NotabilityImportOptions()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(pick.urls.count) files or folders chosen", comment: "Notability import options: what was picked")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Attachments", isOn: $options.attachments)
                    Toggle("Keep Photo Metadata", isOn: $options.keepImageMetadata)
                        .disabled(!options.attachments)
                    Toggle("PDF Page Text", isOn: $options.pdfText)
                        .disabled(!options.attachments)
                    Toggle("Tag Notes with Their Notability Folders", isOn: $options.folderTags)
                } footer: {
                    Text("Attachments are PDF pages, images, typed text and recordings; off imports the ink, Notability's handwriting text and the note's details only. Camera and location data in photos is removed unless you keep it. PDF page text makes the pages searchable.")
                }
                Section {
                    Toggle("Read Handwriting Notability Did Not Index", isOn: $options.recognizeMissing)
                } footer: {
                    Text("Reads the handwriting of pages Notability never recognised, on this device, right after the import.")
                }
            }
            .accessibilityIdentifier("notabilityImportOptions")
            .navigationTitle("Import from Notability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        let urls = pick.urls, notebook = pick.notebook, options = options
                        Task { await model.report { try await model.importNotability(urls, notebook: notebook, options: options) } }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The full report of the last Notability import: what was imported, what was left out and the
/// importer's warnings (the same lines `sempere import notability -v` prints).
struct NotabilityReportView: View {
    @Environment(\.dismiss) private var dismiss
    let details: NotabilityImportDetails

    var body: some View {
        NavigationStack {
            List {
                if !details.imported.isEmpty {
                    Section("Imported") { rows(details.imported) }
                }
                if !details.notImported.isEmpty {
                    Section {
                        rows(details.notImported)
                    } header: {
                        Text("Not Imported")
                    } footer: {
                        Text("Counts of what Notability stores that Sempere does not convert (yet). Everything else of those notes was imported.")
                    }
                }
                if !details.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(Array(details.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(verbatim: warning).font(.footnote).textSelection(.enabled)
                        }
                        if details.moreWarnings > 0 {
                            Text("…and \(details.moreWarnings) more warnings.", comment: "After the first warnings of a Notability import report")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityIdentifier("notabilityReport")
            .navigationTitle("Import Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func rows(_ rows: [NotabilityImportDetails.Row]) -> some View {
        ForEach(rows) { row in
            LabeledContent {
                Text(row.count, format: .number).monospacedDigit()
            } label: {
                Text(verbatim: row.label)
            }
        }
    }
}
