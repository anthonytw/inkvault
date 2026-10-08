import Sempere
import SempereRender
import SwiftUI

/// Settings ▸ Handwritten Math (docs/attachments.md §14 G1 part 2): the
/// "Convert to Math" switch (off by default) and the models it can use, each
/// downloaded only on request, with its size shown first.
struct MathRecognitionSettingsSection: View {
    @AppStorage(MathRecognitionPreference.key) private var enabled = MathRecognitionPreference.defaultValue
    private let models = MathModels.shared

    var body: some View {
        Section {
            Toggle("Convert Handwriting to Math", isOn: $enabled)
            if enabled {
                if models.catalog.isEmpty && !models.isAvailable {
                    Text("No handwriting model is offered for this version of Sempere yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(models.catalog, id: \.id) { entry in
                    ModelRow(entry: entry, models: models)
                }
            }
        } header: {
            Text("Handwritten Math (Experimental)")
        } footer: {
            Text("Insert ▸ Equation from Handwriting reads the ink you circle as LaTeX, with a model that runs on this device: no ink leaves it. A model is downloaded only when you ask, checked against its published fingerprint and kept on this device.")
        }
        .onAppear { models.refresh() }
    }

    private struct ModelRow: View {
        let entry: MathModelCatalogEntry
        let models: MathModels

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.name)
                Text(verbatim: entry.licence).font(.caption).foregroundStyle(.secondary)
                switch models.status[entry.id] ?? .notInstalled {
                case .notInstalled:
                    Button("Download (\(ByteCountFormatter.string(fromByteCount: entry.downloadBytes, countStyle: .file)))") {
                        models.download(entry)
                    }
                case .downloading(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Button("Cancel Download") { models.cancelDownload(entry) }
                case .installed:
                    Text("Installed").foregroundStyle(.secondary)
                    Button("Remove Model", role: .destructive) { models.remove(entry) }
                case .failed(let why):
                    Text(verbatim: why).font(.caption).foregroundStyle(.red)
                    Button("Try Again") { models.download(entry) }
                }
            }
        }
    }
}
