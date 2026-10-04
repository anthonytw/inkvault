import Foundation
import PencilKit
import Testing
@testable import InkVaultApp

/// The tool picker starts with the object (stroke) eraser and keeps the
/// user's later choice of eraser mode.
@MainActor
@Suite(.serialized)
struct EraserPreferenceTests {
    /// An empty defaults suite (one fixed name, emptied per use; the suite runs serially).
    func scratchDefaults() -> UserDefaults {
        let name = "inkvault-eraser-tests"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func eraserItems(_ picker: PKToolPicker) -> [PKToolPickerEraserItem] {
        picker.toolItems.compactMap { $0 as? PKToolPickerEraserItem }
    }

    @Test func defaultsToTheObjectEraser() {
        #expect(EraserPreference.load(from: scratchDefaults()) == .vector)
    }


    @Test func remembersTheLastMode() {
        let d = scratchDefaults()
        for mode in [PKEraserTool.EraserType.bitmap, .fixedWidthBitmap, .vector] {
            EraserPreference.save(mode, to: d)
            #expect(EraserPreference.load(from: d) == mode)
        }
        d.set("garbage", forKey: EraserPreference.defaultsKey)
        #expect(EraserPreference.load(from: d) == .vector)
    }

    /// PencilKit's saved eraser (which restores the pixel eraser over the
    /// item the app passes) is dropped; its other tools are kept.
    @Test func forgetsOnlyPencilKitsSavedEraser() {
        let d = scratchDefaults()
        #expect(!EraserPreference.forgetPencilKitEraser(in: d))
        let pen: [String: Any] = ["identifier": "com.apple.ink.pen", "isSelected": true]
        let eraser: [String: Any] = ["identifier": "com.apple.ink.eraser", "properties": ["PKInkVariantProperty": "default"]]
        d.set(["PKPaletteTools": [pen, eraser], "other": 3], forKey: EraserPreference.pencilKitStateKey)
        #expect(EraserPreference.forgetPencilKitEraser(in: d))
        let state = d.dictionary(forKey: EraserPreference.pencilKitStateKey)
        let tools = state?["PKPaletteTools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["identifier"] as? String } == ["com.apple.ink.pen"])
        #expect(state?["other"] as? Int == 3)
        #expect(!EraserPreference.forgetPencilKitEraser(in: d))
    }

    @Test func pickerKeepsTheSystemToolsAndStartsWithTheChosenEraser() {
        let system = PKToolPicker().toolItems
        // The picker's pixel eraser is the fixed-width one on iPadOS 26 (a
        // `.bitmap` item comes back as `.fixedWidthBitmap`).
        for mode in [PKEraserTool.EraserType.vector, .fixedWidthBitmap] {
            let picker = EraserPreference.makeToolPicker(eraser: mode)
            #expect(picker.toolItems.count == system.count)
            let erasers = eraserItems(picker)
            #expect(erasers.count == 1)
            #expect(erasers.first?.eraserTool.eraserType == mode)
            // Every other tool is still offered, in the same order.
            let kinds = picker.toolItems.map { String(describing: type(of: $0)) }
            #expect(kinds == system.map { String(describing: type(of: $0)) })
        }
    }

    @Test func canvasPickerUsesTheStoredModeAndRecordsTheUsersChoice() throws {
        let key = EraserPreference.defaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        // Whatever PencilKit saved earlier (its pixel eraser), a canvas starts
        // with the object eraser when the user has not chosen another.
        let fresh = PageCanvasHost()
        #expect(eraserItems(fresh.toolPicker).first?.eraserTool.eraserType == .vector)

        // The user switches to the pixel eraser in the picker.
        let host = PageCanvasHost()
        let pixel = PKToolPickerEraserItem(type: .fixedWidthBitmap)
        let picker = PKToolPicker(toolItems: host.toolPicker.toolItems.map { $0 is PKToolPickerEraserItem ? pixel : $0 })
        picker.selectedToolItem = pixel
        host.toolPickerSelectedToolItemDidChange(picker)
        #expect(EraserPreference.load() == .fixedWidthBitmap)
        #expect(eraserItems(PageCanvasHost().toolPicker).first?.eraserTool.eraserType == .fixedWidthBitmap)

        // Choosing a pen does not change the remembered eraser.
        let pen = try #require(picker.toolItems.first { $0 is PKToolPickerInkingItem })
        picker.selectedToolItem = pen
        host.toolPickerSelectedToolItemDidChange(picker)
        #expect(EraserPreference.load() == .fixedWidthBitmap)
    }
}
