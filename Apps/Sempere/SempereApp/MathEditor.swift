import Sempere
import SwiftUI
import UIKit

/// An equation to add or change (Insert → Equation…, or "Edit Equation…" on
/// a selected one).
struct MathRequest: Identifiable {
    let id = UUID()
    let editor: NoteEditor
    let page: UUID
    /// The equation being edited; nil for a new one.
    let item: Item?
    /// Undo for an edit (the canvas's); nil: no undo step.
    let actions: ItemActions?
    /// What is on screen (page points), where a new equation goes.
    let visible: CGRect?
}

/// The style a new equation starts with: the last one used on this device.
enum MathDefaults {
    static let displayKey = "Sempere.mathDisplay"
    static let sizeKey = "Sempere.mathSize"
    static let sizes: ClosedRange<Double> = 6...96

    static func content(_ defaults: UserDefaults = .standard) -> MathContent {
        let size = defaults.double(forKey: sizeKey)
        return MathContent(latex: "", display: defaults.object(forKey: displayKey) as? Bool ?? true,
                           size: sizes.contains(size) ? size : 20, color: .black)
    }

    static func remember(_ content: MathContent, _ defaults: UserDefaults = .standard) {
        defaults.set(content.display, forKey: displayKey)
        defaults.set(content.size, forKey: sizeKey)
    }
}

/// Edits an equation's LaTeX with a live preview typeset by SwiftMath
/// (`MathTypesetter`). Done typesets it, writes the rendered PDF, then one
/// delta (`NoteEditor.insertMath` / `ItemActions.setMath`).
struct MathEditorView: View {
    let request: MathRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var latex: String
    @State private var display: Bool
    @State private var size: Double
    @State private var color: SwiftUI.Color
    @State private var saving = false
    @State private var failure: String?

    init(request: MathRequest) {
        self.request = request
        let start = request.item?.math ?? MathDefaults.content()
        _latex = State(initialValue: start.latex)
        _display = State(initialValue: start.display)
        _size = State(initialValue: start.size)
        _color = State(initialValue: SwiftUI.Color(uiColor: start.color.uiColor))
    }

    /// The value the form describes (the source as typed: `NoteOps.math` normalises it on Done).
    private var content: MathContent {
        MathContent(latex: latex, display: display, size: size, color: Sempere.Color(UIColor(color)))
    }

    private var isEmpty: Bool { latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var problem: String? { isEmpty ? nil : MathTypesetter.problem(latex) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    preview
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .accessibilityIdentifier("mathPreview")
                }
                Section {
                    TextEditor(text: $latex)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 110)
                        .accessibilityIdentifier("mathSource")
                } header: {
                    Text("LaTeX")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Math mode, without $ signs: \\frac{a}{b}, x^{2}, \\sum_{i=1}^{n}, \\sqrt{x}")
                    }
                }
                Section("Style") {
                    Picker("Style", selection: $display) {
                        Text("Display").tag(true)
                        Text("Inline").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: $size, in: MathDefaults.sizes, step: 2) { Text("Size: \(size.formatted(.number.precision(.fractionLength(0)))) pt") }
                    ColorPicker("Colour", selection: $color, supportsOpacity: true)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle(request.item == nil ? "New Equation" : "Edit Equation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.item == nil ? "Add" : "Done") { save() }
                        .disabled(isEmpty || problem != nil || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    @ViewBuilder private var preview: some View {
        if isEmpty {
            Text("Type an equation below").foregroundStyle(.secondary)
        } else if problem == nil, let image = MathTypesetter.image(content, scale: displayScale) {
            ScrollView(.horizontal) {
                Image(decorative: image, scale: displayScale)
                    .padding(4)
                    .background(SwiftUI.Color.white, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
    }

    private func save() {
        saving = true
        failure = nil
        let request = self.request
        Task {
            defer { saving = false }
            do {
                let value = try NoteOps.math(latex, display: display, size: size, color: content.color)
                MathDefaults.remember(value)
                if let item = request.item {
                    if let actions = request.actions {
                        try await actions.setMath(item.id, to: value, on: request.page)
                    } else {
                        try await request.editor.setItemMath(item.id, to: value, on: request.page)
                    }
                } else {
                    try await request.editor.insertMath(value, on: request.page, visible: request.visible)
                }
                dismiss()
            } catch {
                failure = "The equation could not be saved. \(AppModel.describe(error))"
            }
        }
    }
}
