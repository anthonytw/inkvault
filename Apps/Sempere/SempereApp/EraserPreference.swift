import Foundation
import PencilKit

/// The eraser mode the tool picker offers, remembered across canvases and
/// launches in `UserDefaults`.
///
/// A canvas starts with the object (stroke) eraser, `PKEraserTool(.vector)`,
/// unless the user last chose another mode. The user switches mode in the
/// system tool picker: with the eraser selected, tap it again and pick Object
/// Eraser or Pixel Eraser. The picker reports the choice through
/// `PKToolPickerObserver`, and `PageCanvasHost` records it here.
///
/// PencilKit keeps its own copy of the picker's tools in the app's defaults
/// (`PKPaletteNamedDefaults` → `PKPaletteTools`, one entry per tool) and
/// restores it in `PKToolPicker.init`, overriding the eraser item the app
/// passes in; its eraser defaults to the pixel eraser. Measured on the iPadOS
/// 26.5 simulator: a `.vector` eraser item comes back `.fixedWidthBitmap`
/// while that entry exists, and as `.vector` once it is gone (also with a
/// `stateAutosaveName`). So `makeToolPicker` drops PencilKit's saved eraser
/// entry first and this preference decides the eraser; the other tools keep
/// PencilKit's saved state. If PencilKit stores something else there, nothing
/// is removed and the picker shows PencilKit's choice.
enum EraserPreference {
    /// `UserDefaults` key holding the last-used eraser mode.
    static let defaultsKey = "Sempere.eraserType"
    /// The mode a canvas starts with when nothing is stored.
    static var defaultType: PKEraserTool.EraserType { .vector }

    /// The stored eraser mode, or `defaultType`.
    static func load(from defaults: UserDefaults = .standard) -> PKEraserTool.EraserType {
        defaults.string(forKey: defaultsKey).flatMap(type(named:)) ?? defaultType
    }

    /// Remembers `type` as the last-used eraser mode.
    static func save(_ type: PKEraserTool.EraserType, to defaults: UserDefaults = .standard) {
        defaults.set(name(of: type), forKey: defaultsKey)
    }

    /// Stable names for the stored value (the raw values are not API).
    static func name(of type: PKEraserTool.EraserType) -> String {
        switch type {
        case .vector: return "object"
        case .bitmap: return "pixel"
        case .fixedWidthBitmap: return "pixelFixedWidth"
        @unknown default: return "object"
        }
    }

    static func type(named name: String) -> PKEraserTool.EraserType? {
        switch name {
        case "object": return .vector
        case "pixel": return .bitmap
        case "pixelFixedWidth": return .fixedWidthBitmap
        default: return nil
        }
    }

    /// PencilKit's defaults key for its saved tool picker state.
    static let pencilKitStateKey = "PKPaletteNamedDefaults"
    /// The eraser's identifier in PencilKit's saved tools.
    static let pencilKitEraserIdentifier = "com.apple.ink.eraser"

    /// Removes the eraser from PencilKit's saved tool picker state, so the
    /// next `PKToolPicker` keeps the eraser item it is given. Returns whether
    /// anything was removed.
    @discardableResult
    static func forgetPencilKitEraser(in defaults: UserDefaults = .standard) -> Bool {
        guard var state = defaults.dictionary(forKey: pencilKitStateKey) else { return false }
        var removed = false
        for (name, value) in state {
            guard let tools = value as? [[String: Any]] else { continue }
            let kept = tools.filter { ($0["identifier"] as? String) != pencilKitEraserIdentifier }
            if kept.count != tools.count {
                state[name] = kept
                removed = true
            }
        }
        if removed { defaults.set(state, forKey: pencilKitStateKey) }
        return removed
    }

    /// A tool picker with the system's tools, except that its eraser starts
    /// as `eraser`. The user can still switch the eraser's mode in the picker.
    @MainActor
    static func makeToolPicker(eraser: PKEraserTool.EraserType = load()) -> PKToolPicker {
        forgetPencilKitEraser()
        let items = PKToolPicker().toolItems.map { item -> PKToolPickerItem in
            guard item is PKToolPickerEraserItem else { return item }
            return PKToolPickerEraserItem(type: eraser)
        }
        return PKToolPicker(toolItems: items)
    }

    /// The eraser mode of `tool`, if it is an eraser.
    static func eraserType(of tool: PKTool?) -> PKEraserTool.EraserType? {
        (tool as? PKEraserTool)?.eraserType
    }
}
