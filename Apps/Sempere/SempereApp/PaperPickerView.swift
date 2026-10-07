import Sempere
import SwiftUI
import UIKit

/// Visual paper picker: a grid of live thumbnails (one per kind, drawn with
/// `PaperRenderer` through `PaperImage`), a large preview of the selection and
/// controls for its parameters. Used for a new note (`.newNote`) and for the
/// open note's page settings (`.page`).
struct PaperPickerView: View {
    enum Purpose {
        case newNote
        /// The page on the canvas, `number` of `count`.
        case page(number: Int, count: Int)
    }

    /// What the user chose to do with the paper.
    enum Choice {
        /// New note: use it for the note.
        case use
        case thisPage
        case allPages
    }

    let purpose: Purpose
    /// Called with the paper as it is edited (and nil when the sheet closes),
    /// so the canvas behind can follow live.
    let onPreview: (Paper?) -> Void
    let onChoose: (Paper, Choice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var draft: PaperDraft
    @State private var savedAsDefault = false

    init(paper: Paper, purpose: Purpose, onPreview: @escaping (Paper?) -> Void = { _ in },
         onChoose: @escaping (Paper, Choice) -> Void) {
        _draft = State(initialValue: PaperDraft(paper: paper))
        self.purpose = purpose
        self.onPreview = onPreview
        self.onChoose = onChoose
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    kindGrid
                    if sizeClass == .regular {
                        HStack(alignment: .top, spacing: 32) {
                            preview
                            controls.frame(maxWidth: .infinity)
                        }
                    } else {
                        preview.frame(maxWidth: .infinity)
                        controls
                    }
                }
                .padding()
            }
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .onChange(of: draft.paper) { _, paper in
            savedAsDefault = false
            onPreview(paper)
        }
        .onDisappear { onPreview(nil) }
    }

    // MARK: Kinds

    private var kindGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)], spacing: 14) {
            ForEach(PaperKind.allCases, id: \.self) { kind in
                Button { draft.select(kind) } label: {
                    VStack(spacing: 6) {
                        thumbnail(for: kind)
                        Text(kind.localizedTitle).font(.caption).foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind.localizedTitle)
                .accessibilityAddTraits(kind == draft.kind ? .isSelected : [])
            }
        }
    }

    private func thumbnail(for kind: PaperKind) -> some View {
        var paper = kind == draft.kind ? draft.paper : Paper.template(kind)
        if kind != draft.kind { paper.background = draft.paper.background }
        let selected = kind == draft.kind
        return Image(uiImage: PaperImage.image(for: paper, size: CGSize(width: 120, height: 155), scale: displayScale))
            .resizable()
            .aspectRatio(612.0 / 792.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary.opacity(0.4),
                                                                 lineWidth: selected ? 3 : 1))
    }

    // MARK: Preview and parameters

    private var preview: some View {
        Image(uiImage: PaperImage.image(for: draft.paper, size: CGSize(width: 340, height: 440), scale: displayScale))
            .resizable()
            .aspectRatio(612.0 / 792.0, contentMode: .fit)
            .frame(maxWidth: 340)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(SwiftUI.Color.secondary.opacity(0.5), lineWidth: 1))
            .shadow(radius: 6, y: 2)
            .accessibilityLabel("Preview of \(draft.kind.localizedTitle) paper")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(draft.parameters) { parameter in
                parameterRow(parameter)
            }
            if draft.hasLineColor {
                colorRow(draft.kind == .dot || draft.kind == .isoDot ? String(localized: "Dot colour") : String(localized: "Line colour"),
                         get: { draft.paper.lineColor }, set: { draft.setLineColor($0) })
            }
            if draft.hasMarginColor {
                colorRow(String(localized: "Margin colour"), get: { draft.paper.marginColor }, set: { draft.setMarginColor($0) })
            }
            backgroundRow
            Button("Reset to Defaults", systemImage: "arrow.counterclockwise") { draft.reset() }
                .buttonStyle(.bordered)
        }
    }

    private func parameterRow(_ parameter: PaperParameter) -> some View {
        let value = Binding(get: { draft.value(of: parameter) }, set: { draft.set(parameter, to: $0) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parameter.title)
                Spacer()
                Text(Self.format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                Stepper(parameter.title, value: value, in: parameter.range, step: parameter.step * (parameter.step < 1 ? 2 : 1))
                    .labelsHidden()
            }
            Slider(value: value, in: parameter.range, step: parameter.step)
                .accessibilityLabel(parameter.title)
        }
    }

    private static func format(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...2))) + " pt"
    }

    private func colorRow(_ title: String, get: @escaping () -> Sempere.Color,
                          set: @escaping (Sempere.Color) -> Void) -> some View {
        ColorPicker(title, selection: Binding(
            get: { SwiftUI.Color(uiColor: get().uiColor) },
            set: { set(Sempere.Color(UIColor($0))) }), supportsOpacity: true)
    }

    private var backgroundRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page colour")
            HStack(spacing: 12) {
                ForEach(PaperBackground.allCases) { preset in
                    Button { draft.select(preset) } label: {
                        VStack(spacing: 4) {
                            Circle().fill(SwiftUI.Color(uiColor: preset.color.uiColor))
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(draft.background == preset ? SwiftUI.Color.accentColor
                                                                                    : SwiftUI.Color.secondary.opacity(0.5),
                                                         lineWidth: draft.background == preset ? 3 : 1))
                            Text(preset.title).font(.caption).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title) page")
                    .accessibilityAddTraits(draft.background == preset ? .isSelected : [])
                }
                Spacer()
                ColorPicker("Custom page colour", selection: Binding(
                    get: { SwiftUI.Color(uiColor: draft.paper.background.uiColor) },
                    set: { draft.setBackgroundColor(Sempere.Color(UIColor($0))) }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons }
            VStack(spacing: 8) { actionButtons }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch purpose {
        case .newNote:
            Button("Use This Paper") { choose(.use) }
                .buttonStyle(.borderedProminent)
        case .page(let number, let count):
            Button("Apply to This Page") { choose(.thisPage) }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Page \(number) of \(count)")
            Button("Apply to All Pages") { choose(.allPages) }
                .buttonStyle(.bordered)
        }
        Button(savedAsDefault ? "Saved as Default" : "Use as Default for New Notes",
               systemImage: savedAsDefault ? "checkmark" : "star") {
            PaperPreference.save(draft.paper)
            savedAsDefault = true
        }
        .buttonStyle(.bordered)
        .disabled(savedAsDefault)
    }

    private func choose(_ choice: Choice) {
        onChoose(draft.paper, choice)
        dismiss()
    }
}
