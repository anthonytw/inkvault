import SwiftUI

/// Shown while no vault is open: recents, vaults on this device, and the
/// ways to open or create one.
struct WelcomeView: View {
    @Environment(VaultLibrary.self) private var library
    var openFolder: () -> Void
    var newVault: () -> Void
    var openRecent: (RecentVault) -> Void
    var openURL: (URL) -> Void

    @State private var onDevice: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Vault…", systemImage: "plus.circle", action: newVault)
                    Button("Open Vault…", systemImage: "folder", action: openFolder)
                } footer: {
                    Text("A vault is one .inkvault item in Files: on this device, in iCloud Drive, or anywhere else. Choose the .inkvault item itself (a plain folder works too).")
                }
                if !library.recents.isEmpty {
                    Section("Recent") {
                        ForEach(library.recents) { entry in
                            Button { openRecent(entry) } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.lastOpened, format: .relative(presentation: .named))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Remove", role: .destructive) { library.forget(entry) } }
                        }
                    }
                }
                if !onDevice.isEmpty {
                    Section("On This Device") {
                        ForEach(onDevice, id: \.self) { url in
                            Button(VaultLibrary.displayName(of: url), systemImage: "ipad") { openURL(url) }
                        }
                    }
                }
            }
            .navigationTitle("InkVault")
            .onAppear { onDevice = VaultLibrary.vaults(in: VaultLibrary.onDeviceFolder) }
        }
    }
}
