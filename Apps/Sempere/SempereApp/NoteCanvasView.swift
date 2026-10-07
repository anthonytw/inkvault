import Sempere
import SwiftUI

/// The selected note: one page at a time on the canvas, with page controls.
/// Opens a `NoteEditor` through the model when the selection changes and
/// saves when the app goes to the background.
struct NoteCanvasView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ColumnLayout.key) private var storedColumns = "all"
    @Environment(WindowUI.self) private var ui
    @State private var showingHistory = false
    @AppStorage(KeepScreenOn.key) private var keepScreenOn = false

    var body: some View {
        Group {
            if let note = model.selectedNote {
                if model.windowClaims.contains(note.id) {
                    ContentUnavailableView("Open in Its Own Window", systemImage: "macwindow",
                                           description: Text("This note is shown in a window of its own."))
                } else if model.canvasWindow != ui.id {
                    // Another library window shows the canvas: one canvas per editor.
                    ContentUnavailableView {
                        Label("Shown in Another Window", systemImage: "macwindow.on.rectangle")
                    } actions: {
                        Button("Show Here") { model.canvasWindow = ui.id }
                    }
                } else if let editor = model.editor, editor.noteID == note.id {
                    EditorView(editor: editor)
                        .navigationTitle(NoteTitle.display(note.title))
                } else if let failure = model.editorFailure, failure.id == note.id {
                    ContentUnavailableView {
                        Label("Could Not Open Note", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(failure.message)
                    } actions: {
                        Button("Try Again") { Task { await model.showSelectedNote() } }
                    }
                } else if let download = model.noteDownload, download.id == note.id {
                    VStack(spacing: 10) {
                        ProgressView(value: download.progress.fractionCompleted).frame(width: 240)
                        Text("Downloading this note from iCloud: \(download.progress.downloaded) of "
                             + "\(download.progress.total) file\(download.progress.total == 1 ? "" : "s")")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if model.pendingNoteIDs.contains(note.id) {
                    ProgressView("Downloading this note from iCloud…")
                } else {
                    ProgressView("Opening…")
                }
            } else {
                ContentUnavailableView("No Note Selected", systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let id = model.selectedNoteID { HistoryView(noteID: id) }
        }
        .toolbar {
            if let note = model.selectedNote {
                // The title itself: tap it, or press and hold it, to rename the note.
                ToolbarItem(placement: .principal) {
                    Button {
                        startRename(note)
                    } label: {
                        HStack(spacing: 4) {
                            Text(NoteTitle.display(note.title)).font(.headline).lineLimit(1)
                            Image(systemName: "pencil").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in startRename(note) })
                    .accessibilityLabel("Note title: \(NoteTitle.display(note.title))")
                    .accessibilityHint("Renames the note")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Rename…", systemImage: "pencil") { startRename(note) }
                }
                ToolbarItem(placement: .secondaryAction) {
                    ExportMenu(ids: [note.id])
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save Version…", systemImage: "bookmark") { ui.saveVersionNoteID = note.id }
                        .disabled(note.deleted)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Version History…", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Toggle("Keep Screen On", systemImage: "sun.max", isOn: $keepScreenOn)
                }
                ToolbarItem(placement: Platform.isPhone ? .secondaryAction : .primaryAction) {
                    Button("Tags", systemImage: note.tags.isEmpty ? "tag" : "tag.fill") { ui.tagsNoteID = note.id }
                }
            }
            if !Platform.isPhone {   // the stack's back button is the way to the list
                ToolbarItem(placement: .topBarLeading) {
                    let full = ColumnLayout.visibility(from: storedColumns) == .detailOnly
                    Button(full ? "Show Notes" : "Hide Notes",
                           systemImage: full ? "list.bullet" : "arrow.up.left.and.arrow.down.right") {
                        withAnimation { storedColumns = ColumnLayout.toggled(storedColumns) }
                    }
                    .disabled(!full && model.selectedNote == nil)
                    .help(full ? "Show the note list" : "Hide the note list for a full-width canvas")
                }
            }
        }
        .task(id: ShowKey(note: model.phase == .unlocked ? model.selectedNoteID : nil,
                          claimed: model.selectedNoteID.map { model.windowClaims.contains($0) } ?? false,
                          epoch: model.keyEpoch)) {
            await model.showSelectedNote()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, let editor = model.editor {
                Task { await editor.flush() }
            }
        }
    }

    /// What the detail pane has to show: another note, a window taking or
    /// giving a note back, or a key change (every editor was closed).
    private struct ShowKey: Hashable {
        var note: UUID?
        var claimed: Bool
        var epoch: Int
    }

    /// Opens the rename alert (`AppModel.renameNote`, one `setMeta(.title)` delta).
    private func startRename(_ note: NoteSummary) {
        guard ui.renameNoteID == nil else { return }
        ui.renameNoteID = note.id
    }
}

/// The canvas of one note with its toolbar: the library window's detail pane
/// and the note windows (`NoteWindowView`) both show it.
struct EditorView: View {
    let editor: NoteEditor
    @Environment(WindowUI.self) private var ui
    @Environment(AppModel.self) private var model
    /// Selection mode for placed items (images, text boxes, PDF pages).
    @State private var selectingItems = false
    /// The text tool: a tap edits a text box or starts a new one (`TextBoxEditorController`).
    @State private var addingText = false
    @AppStorage(ToolPalette.visibleKey) private var paletteVisible = true
    @AppStorage(ToolPalette.compactKey) private var paletteCompact = false
    @AppStorage(ObjectEraserSize.defaultsKey) private var eraserRadius = ObjectEraserSize.defaultRadius
    /// iPhone only: finger annotation is off until the pencil button turns it on.
    @State private var annotating = false
    @AppStorage(PageStrip.visibleKey) private var stripVisible = false
    /// Deleted pages the undo banner has already been shown for.
    @State private var undoBannerFor = 0

    var body: some View {
        @Bindable var ui = ui
        VStack(spacing: 0) {
            if let reason = editor.readOnlyReason {
                Banner(text: reason, systemImage: "lock", tint: .secondary)
            }
            if let error = editor.saveError {
                Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if undoBannerFor > 0, undoBannerFor == editor.deletedPages.count {
                HStack {
                    Label("Page deleted.", systemImage: "trash").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { editor.undoDeletePage() }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                .task(id: undoBannerFor) {
                    try? await Task.sleep(for: .seconds(6))
                    undoBannerFor = 0
                }
            }
            if let page = editor.currentPage {
                PageCanvasView(editor: editor, pageID: page.id, paper: editor.displayedPaper(of: page), pageSize: editor.pageSize,
                               paletteVisible: paletteVisible,
                               paletteCompact: PhoneReading.paletteCompact(isPhone: Platform.isPhone, stored: paletteCompact),
                               drawingSuspended: PhoneReading.drawingSuspended(isPhone: Platform.isPhone, annotating: annotating),
                               generation: editor.canvasGeneration,
                               itemSource: model.itemLayerSource, itemCommands: model.itemCommands,
                               selectingItems: selectingItems, onSelectingItemsEnded: { selectingItems = false },
                               addingText: addingText, onAddingTextEnded: { addingText = false })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc")
                } description: {
                    Text("This note has no pages yet.")
                } actions: {
                    if !editor.isReadOnly {
                        Button("Add Page") { editor.addPage() }
                    }
                }
            }
        }
        .inspector(isPresented: Binding(get: { stripVisible && !editor.isPageless }, set: { stripVisible = $0 })) {
            PageStripView(editor: editor)
                .inspectorColumnWidth(min: 150, ideal: 180, max: 260)
        }
        .onChange(of: editor.deletedPages.count) { old, new in
            undoBannerFor = new > old ? new : 0
        }
        #if DEBUG
        .task {
            // App Store screenshots: show the paper picker over the note (DemoLaunch).
            if DebugLaunch.environment["SEMPERE_DEMO_PAPER_PICKER"] != nil {
                try? await Task.sleep(for: .seconds(2))
                ui.choosingPaper = true
            }
        }
        #endif
        .sheet(isPresented: $ui.choosingPaper) {
            if let page = editor.currentPage {
                PaperPickerView(paper: editor.displayedPaper(of: page),
                                purpose: .page(number: editor.pageIndex + 1, count: editor.pages.count),
                                onPreview: { editor.showPaperPreview($0) },
                                onChoose: { paper, choice in editor.setPaper(paper, allPages: choice == .allPages) })
            }
        }
        .onChange(of: editor.noteID) {
            annotating = PhoneReading.annotatingAfterNoteChange()
            selectingItems = false
            addingText = false
        }
        .onChange(of: selectingItems) { if selectingItems { addingText = false } }
        .onChange(of: addingText) { if addingText { selectingItems = false } }
        .toolbar {
            if Platform.isPhone { phoneToolbar } else { fullToolbar }
        }
    }

    /// The iPhone's toolbar: one pencil button for light annotation, page
    /// controls in the bottom bar (in a menu while annotating, so the bar does
    /// not sit on the palette), the rest in the overflow menu.
    @ToolbarContentBuilder
    private var phoneToolbar: some ToolbarContent {
        if !editor.isReadOnly {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Annotate", systemImage: annotating ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle",
                       isOn: $annotating)
                    .toggleStyle(.button)
                    .help("Draw on the page with a finger")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Paper…", systemImage: "square.grid.3x3") { ui.choosingPaper = true }
                    .disabled(editor.currentPage == nil)
            }
            if annotating {
                ToolbarItem(placement: .secondaryAction) { textToolToggle }
                ToolbarItem(placement: .secondaryAction) { eraserSizeMenu }
                if showsItemSelection {
                    ToolbarItem(placement: .secondaryAction) { itemSelectionToggle }
                }
            }
        }
        if annotating, editor.pages.count > 1 || !editor.isReadOnly {
            ToolbarItem(placement: .secondaryAction) {
                Menu("Pages", systemImage: "doc.on.doc") { pageButtons }
            }
        } else if editor.pages.count > 1 {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous Page", systemImage: "chevron.left") { editor.selectPage(editor.pageIndex - 1) }
                    .disabled(editor.pageIndex == 0)
                Spacer()
                pageCounter
                Spacer()
                Button("Next Page", systemImage: "chevron.right") { editor.selectPage(editor.pageIndex + 1) }
                    .disabled(editor.pageIndex + 1 >= editor.pages.count)
            }
        }
    }

    /// Whether the Select Items toggle is offered: the note can be edited and
    /// the page has items (or there are copied items to paste).
    private var showsItemSelection: Bool {
        guard !editor.isReadOnly, let page = editor.currentPage else { return false }
        return !page.items.isEmpty || model.itemClipboard.entry != nil || selectingItems
    }

    private var textToolToggle: some View {
        Toggle("Text", systemImage: "character.textbox", isOn: $addingText)
            .toggleStyle(.button)
            .help("Type text: tap the page for a new text box, or a text box to edit it")
    }

    private var itemSelectionToggle: some View {
        Toggle("Select Items", systemImage: "cursorarrow.rays", isOn: $selectingItems)
            .toggleStyle(.button)
            .help("Select, move, resize and delete images, text boxes and PDF pages")
    }

    private var pageCounter: some View {
        Text(editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
            .monospacedDigit()
    }

    @ViewBuilder
    private var pageButtons: some View {
        Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
            .disabled(editor.pageIndex == 0)
        Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
            .disabled(editor.pageIndex + 1 >= editor.pages.count)
        if !editor.isReadOnly {
            Button("Add Page", systemImage: "doc.badge.plus") { editor.addPage() }
        }
        Text(editor.pages.isEmpty ? "No pages" : "Page \(editor.pageIndex + 1) of \(editor.pages.count)")
    }

    private var eraserSizeMenu: some View {
        // PencilKit's object eraser has no size; the app's does (ObjectEraser.swift).
        Menu {
            Picker("Object Eraser Size", selection: $eraserRadius) {
                ForEach(ObjectEraserSize.radii, id: \.self) { r in
                    Text("\(ObjectEraserSize.name(of: r)) – \(Int(r)) pt").tag(r)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Object Eraser Size", systemImage: "eraser.line.dashed")
        }
        .help("Size of the object eraser; the pixel eraser's size is in the tool palette")
    }

    /// The iPad's and the Mac's toolbar.
    @ToolbarContentBuilder
    private var fullToolbar: some ToolbarContent {
            if !editor.isReadOnly {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Paper…", systemImage: "square.grid.3x3") { ui.choosingPaper = true }
                        .disabled(editor.currentPage == nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    // Switching never deletes ink (format.md §5.4.3); it is one delta.
                    Picker(selection: Binding(
                        get: { editor.isPageless },
                        set: { pageless in Task { await editor.setLayout(pageless: pageless) } })) {
                        Label("Pages", systemImage: "doc.on.doc").tag(false)
                        Label("Pageless", systemImage: "scroll").tag(true)
                    } label: {
                        Label("Page Layout", systemImage: "rectangle.split.1x2")
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .primaryAction) {
                    // Tap: show or hide the palette. Press and hold: compact palette.
                    Menu {
                        Toggle("Compact Palette", systemImage: "rectangle.compress.vertical", isOn: $paletteCompact)
                    } label: {
                        Label(paletteVisible ? "Hide Tools" : "Show Tools",
                              systemImage: paletteVisible ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    } primaryAction: {
                        paletteVisible.toggle()
                    }
                }
            }
            if !editor.isReadOnly, editor.currentPage != nil {
                ToolbarItem(placement: .primaryAction) { textToolToggle }
            }
            if showsItemSelection {
                ToolbarItem(placement: .primaryAction) { itemSelectionToggle }
            }
            if !editor.isReadOnly {
                ToolbarItem(placement: .primaryAction) {
                    // PencilKit's object eraser has no size; the app's does (ObjectEraser.swift).
                    Menu {
                        Picker("Object Eraser Size", selection: $eraserRadius) {
                            ForEach(ObjectEraserSize.radii, id: \.self) { r in
                                Text("\(ObjectEraserSize.name(of: r)) – \(Int(r)) pt").tag(r)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Object Eraser Size", systemImage: "eraser.line.dashed")
                    }
                    .help("Size of the object eraser; the pixel eraser's size is in the tool palette")
                }
            }
            // A pageless note is one page (an older one may have several: they can be browsed).
            if editor.pages.count > 1 || (!editor.isReadOnly && !editor.isPageless) {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Previous Page", systemImage: "chevron.up") { editor.selectPage(editor.pageIndex - 1) }
                        .disabled(editor.pageIndex == 0)
                    Text(editor.pages.isEmpty ? "–" : "\(editor.pageIndex + 1) / \(editor.pages.count)")
                        .monospacedDigit()
                    Button("Next Page", systemImage: "chevron.down") { editor.selectPage(editor.pageIndex + 1) }
                        .disabled(editor.pageIndex + 1 >= editor.pages.count)
                    if !editor.isReadOnly && !editor.isPageless {
                        // Tap: a page after this one. Press and hold: the other page actions.
                        Menu {
                            Button("Add Page After This One", systemImage: "doc.badge.plus") { editor.addPageAfterCurrent() }
                            Button("Add Page at End", systemImage: "arrow.down.to.line") { editor.addPage() }
                            if let page = editor.currentPage {
                                Button("Duplicate Page", systemImage: "plus.square.on.square") { editor.duplicatePage(page.id) }
                                Button("Delete Page", systemImage: "trash", role: .destructive) { editor.deletePage(page.id) }
                                    .disabled(!editor.canDeletePage)
                            }
                            if !editor.deletedPages.isEmpty {
                                Button("Undo Delete Page", systemImage: "arrow.uturn.backward") { editor.undoDeletePage() }
                            }
                        } label: {
                            Label("Add Page", systemImage: "doc.badge.plus")
                        } primaryAction: {
                            editor.addPageAfterCurrent()
                        }
                    }
                    if !editor.isPageless {
                        Button(stripVisible ? "Hide Pages" : "Show Pages", systemImage: "sidebar.right") {
                            stripVisible.toggle()
                        }
                        .help("Page thumbnails: tap to go to a page, drag to reorder")
                    }
                }
            }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: SwiftUI.Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
    }
}

/// How a note's title is shown.
enum NoteTitle {
    static func display(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }
}
