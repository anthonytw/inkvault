#if DEBUG
import Age
import Foundation
import InkVault
import UIKit

/// Debug builds only: open a vault, unlock it and show a note straight from
/// launch environment variables, without the folder picker, so a simulator
/// run can be scripted (`xcrun simctl launch` with `SIMCTL_CHILD_` prefixes):
///
/// - `INKVAULT_DEBUG_VAULT`: path of a `.inkvault` folder.
/// - `INKVAULT_DEBUG_IDENTITY`: path of an age identity file.
/// - `INKVAULT_DEBUG_NOTE`: note id (or a unique prefix of it) to open.
/// - `INKVAULT_DEBUG_SCROLL_Y`: page y (points) to scroll the canvas to.
/// - `INKVAULT_DEBUG_ZOOM`: zoom as a multiple of the fit-width zoom.
/// - `INKVAULT_DEBUG_SNAPSHOT`: path to write a PNG of the canvas to, once shown.
///
/// Release builds compile none of this.
enum DebugLaunch {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// True when the launch environment names a vault.
    static var isActive: Bool { environment["INKVAULT_DEBUG_VAULT"] != nil }

    /// Page y to scroll to after a note opens, if requested.
    static var scrollY: Double? { environment["INKVAULT_DEBUG_SCROLL_Y"].flatMap(Double.init) }

    /// Opens what the environment names; errors land in `model.errorMessage`.
    @MainActor
    static func run(_ model: AppModel) async {
        let env = environment
        guard let vaultPath = env["INKVAULT_DEBUG_VAULT"] else { return }
        await model.report {
            let url = URL(fileURLWithPath: vaultPath)
            if let keyPath = env["INKVAULT_DEBUG_IDENTITY"] {
                let text = try String(contentsOfFile: keyPath, encoding: .utf8)
                try await model.openVault(at: url)
                try await model.unlock(identityText: text)
            } else {
                try await model.openVault(at: url)
            }
            if let note = env["INKVAULT_DEBUG_NOTE"]?.lowercased(),
               let match = model.notes.first(where: { $0.id.uuidString.lowercased().hasPrefix(note) }) {
                model.selectedNoteID = match.id
            }
        }
    }

    /// The first layout of a canvas: applies the requested zoom and scroll,
    /// logs the geometry and writes the snapshot, if asked.
    @MainActor
    static func canvasDidLayOut(_ host: PageCanvasHost) {
        let env = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak host] in
            guard let host else { return }
            let canvas = host.canvas
            if let z = env["INKVAULT_DEBUG_ZOOM"].flatMap(Double.init) {
                canvas.zoomScale = canvas.minimumZoomScale * CGFloat(z)
            }
            canvas.setContentOffset(CGPoint(x: 0, y: CGFloat(scrollY ?? 0) * canvas.zoomScale), animated: false)
            NSLog("InkVaultDebug zoom=%f contentSize=%@ offset=%@ bounds=%@", canvas.zoomScale,
                  NSCoder.string(for: canvas.contentSize), NSCoder.string(for: canvas.contentOffset),
                  NSCoder.string(for: host.bounds))
            guard let path = env["INKVAULT_DEBUG_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak host] in
                guard let host else { return }
                let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
                    host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: URL(fileURLWithPath: path))
                NSLog("InkVaultDebug snapshot %@", path)
            }
        }
    }
}
#endif
