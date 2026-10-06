// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore

/// The chain editor: a drag-to-reorder list of effects with bypass checkboxes,
/// custom names and Open buttons, plus Add…, –, Duplicate and Rename, and
/// ⌘C/⌘V/⌘D/⌘R on the selected row (Return renames it too).
/// Holds no chain state; it asks `rows()` on reload.
///
/// ⌘C/⌘V/⌘D/⌘R arrive as `copy:`/`paste:`/`duplicateSlot:`/`renameSlot:` from the
/// app's hidden Edit menu: the table does not answer them, so they travel up the
/// responder chain to the window and on to this controller. A text field (the Add
/// picker's search, or a name being edited) gets them first, so typing there still
/// copies and pastes text.
final class ChainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation, NSWindowDelegate {
    struct Row: Equatable {
        var slot: ChainSlot
        var error: String?
    }

    var rows: () -> [Row] = { [] }
    var catalog: () -> [CatalogEntry] = { [] }
    var pinned: () -> [String] = { [] }
    var onTogglePin: (CatalogEntry) -> Void = { _ in }
    var onReenable: (CatalogEntry) -> Void = { _ in }
    var onBypass: (UUID, Bool) -> Void = { _, _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onAdd: (CatalogEntry) -> Void = { _ in }
    var onOpen: (UUID) -> Void = { _ in }
    /// Appends a copy of the slot to the end of the chain; calls back with the new
    /// slot's id (later, if the plugin's settings take a moment to read).
    var onDuplicate: (UUID, @escaping (UUID?) -> Void) -> Void = { _, done in done(nil) }
    /// Copies the slot, with its current settings, to the clipboard.
    var onCopy: (UUID) -> Void = { _ in }
    /// Pastes the copied slot below the given one (or at the end); returns the new id.
    var onPaste: (UUID?) -> UUID? = { _ in nil }
    var canPaste: () -> Bool = { false }
    /// Sets (or, with nil, clears) a slot's custom name.
    var onRename: (UUID, String?) -> Void = { _, _ in }
    /// False until editor windows exist (Task 11).
    var canOpen = false

    private static let dragType = NSPasteboard.PasteboardType("com.nicholaspsmith.SoundChain.row")
    private let table = ChainTableView()
    private let removeButton = NSButton(title: "–", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    /// The slot whose name is being edited. Reloads wait until it is done, since
    /// a reload rebuilds the rows and would throw the edit away.
    private var editingID: UUID?
    private var reloadPending = false
    private var current: [Row] = []
    private var addPopover: NSPopover?
    /// After a removal, the row index to select next (so repeated – presses keep deleting).
    private var selectAfterRemove: Int?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 340),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SoundChain"
        window.minSize = NSSize(width: 460, height: 220)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        reload()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-reads the rows, keeping the selection on the same slot.
    func reload() {
        guard editingID == nil else { reloadPending = true; return }
        reloadPending = false
        let selected = current.indices.contains(table.selectedRow) ? current[table.selectedRow].slot.id : nil
        current = rows()
        table.reloadData()
        if let selected, let row = current.firstIndex(where: { $0.slot.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if let row = selectAfterRemove, !current.isEmpty {
            table.selectRowIndexes([min(row, current.count - 1)], byExtendingSelection: false)
        }
        selectAfterRemove = nil
        updateButtons()
    }

    /// Selects a slot (a new copy) and scrolls it into view.
    func select(_ id: UUID) {
        if !current.contains(where: { $0.slot.id == id }) { reload() }
        guard let row = current.firstIndex(where: { $0.slot.id == id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window?.makeFirstResponder(table)
    }

    private var selectedID: UUID? {
        current.indices.contains(table.selectedRow) ? current[table.selectedRow].slot.id : nil
    }

    private func updateButtons() {
        removeButton.isEnabled = selectedID != nil
        duplicateButton.isEnabled = selectedID != nil
        renameButton.isEnabled = selectedID != nil
    }

    private func buildContent() {
        let column = NSTableColumn(identifier: .init("slot"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        table.onReturn = { [weak self] in self?.renameSlot(nil) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add…", target: self, action: #selector(showAdd(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.isEnabled = false
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicateSlot(_:))
        duplicateButton.isEnabled = false
        duplicateButton.toolTip = "Adds a copy of the selected effect, with the same settings, to the end of the chain (⌘D)"
        renameButton.target = self
        renameButton.action = #selector(renameSlot(_:))
        renameButton.isEnabled = false
        renameButton.toolTip = "Gives the selected effect a name of your own (Return or ⌘R)"
        let buttons = NSStackView(views: [addButton, removeButton, duplicateButton, renameButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = BackgroundClickView()
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window?.contentView = content
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { current.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = current[row]
        let id = entry.slot.id
        return SlotRowView(row: entry, canOpen: canOpen,
                           onEnabled: { [weak self] enabled in self?.onBypass(id, !enabled) },
                           onOpen: { [weak self] in self?.onOpen(id) },
                           onBeginEditing: { [weak self] in self?.beginEditing(id) },
                           onEndEditing: { [weak self] name in self?.endEditing(id, name: name) })
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    /// Keep the dragged row centred on the cursor (the default image floats well above it).
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        guard let window = tableView.window else { return }
        let cursor = tableView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        session.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self],
                                       searchOptions: [:]) { item, _, _ in
            var frame = item.draggingFrame
            frame.origin.y = cursor.y - frame.height / 2
            item.draggingFrame = frame
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) === table else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(text) else { return false }
        onMove(from, row)
        return true
    }

    // MARK: Buttons

    @objc private func removeSelected() {
        guard current.indices.contains(table.selectedRow) else { return }
        selectAfterRemove = table.selectedRow
        onRemove(current[table.selectedRow].slot.id)
    }

    @objc func duplicateSlot(_ sender: Any?) {
        guard let id = selectedID else { return }
        onDuplicate(id) { [weak self] newID in
            if let newID { self?.select(newID) }
        }
    }

    // MARK: Custom names

    /// Rename button, ⌘R, or Return on a row: edits the selected row's name in place.
    @objc func renameSlot(_ sender: Any?) {
        guard let id = selectedID else { return }
        beginEditing(id)
    }

    /// Selects the row and turns its name into a text field.
    private func beginEditing(_ id: UUID) {
        guard editingID == nil || editingID == id,
              let row = current.firstIndex(where: { $0.slot.id == id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SlotRowView else { return }
        editingID = id
        view.beginEditingName()
    }

    /// `name` is nil when the edit was cancelled (Escape); otherwise it is what was
    /// typed, which may be empty (clearing the name).
    private func endEditing(_ id: UUID, name: String?) {
        guard editingID == id else { return }
        editingID = nil
        if let name { onRename(id, name) }
        reload()
        // Return or Escape leave nothing focused: hand the keyboard back to the
        // table (once the edit has fully ended) so Return can rename again.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(self.table) }
        }
    }

    /// Clicking away from the window, or closing it, commits a name being edited.
    func windowDidResignKey(_ notification: Notification) { finishEditing() }
    func windowWillClose(_ notification: Notification) { finishEditing() }

    private func finishEditing() {
        guard editingID != nil, window?.firstResponder is NSTextView else { return }
        window?.makeFirstResponder(nil)
    }

    // MARK: Copy and paste (Edit menu, through the responder chain)

    @objc func copy(_ sender: Any?) {
        guard let id = selectedID else { return }
        onCopy(id)
    }

    @objc func paste(_ sender: Any?) {
        guard let newID = onPaste(selectedID) else { NSSound.beep(); return }
        select(newID)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(duplicateSlot(_:)), #selector(renameSlot(_:)): return selectedID != nil
        case #selector(paste(_:)): return canPaste()
        default: return true
        }
    }

    @objc private func showAdd(_ sender: NSButton) {
        let picker = AddEffectViewController(entries: catalog(), pins: pinned,
                                             onTogglePin: onTogglePin, onReenable: onReenable) { [weak self] entry in
            self?.addPopover?.close()
            self?.onAdd(entry)
        }
        let popover = NSPopover()
        popover.contentViewController = picker
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        addPopover = popover
    }
}

/// The chain table. Return on a selected row starts renaming it.
final class ChainTableView: NSTableView {
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, selectedRow >= 0 {
            onReturn()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The window's background: a click on it ends a name edit (committing it).
final class BackgroundClickView: NSView {
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        super.mouseDown(with: event)
    }
}

/// One chain row: drag hint, plugin icon, enable checkbox with the plugin name and
/// the manufacturer or error underneath (red), the custom name (click to edit),
/// and an Open button.
final class SlotRowView: NSView {
    static let nameColumnWidth: CGFloat = 150
    private let onEnabled: (Bool) -> Void
    private let onOpen: () -> Void
    private let name: SlotNameView

    init(row: ChainWindowController.Row, canOpen: Bool,
         onEnabled: @escaping (Bool) -> Void, onOpen: @escaping () -> Void,
         onBeginEditing: @escaping () -> Void, onEndEditing: @escaping (String?) -> Void) {
        self.onEnabled = onEnabled
        self.onOpen = onOpen
        name = SlotNameView(customName: row.slot.customName, onBeginEditing: onBeginEditing,
                            onEndEditing: onEndEditing)
        super.init(frame: .zero)

        let handle = NSTextField(labelWithString: "≡")
        handle.textColor = .tertiaryLabelColor

        let check = NSButton(checkboxWithTitle: row.slot.name, target: self, action: #selector(toggled(_:)))
        check.state = row.slot.bypassed ? .off : .on
        check.lineBreakMode = .byTruncatingTail
        check.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        check.toolTip = "\(row.slot.name) — \(row.slot.manufacturer)"

        let detail = NSTextField(labelWithString: row.error ?? row.slot.manufacturer)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = row.error == nil ? .secondaryLabelColor : .systemRed
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let error = row.error { detail.toolTip = error }

        let text = NSStackView(views: [check, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = PluginIcons.view(for: row.slot.component, size: 26)
        icon.alphaValue = row.slot.bypassed || row.error != nil ? 0.45 : 1

        let open = NSButton(title: "Open", target: self, action: #selector(openTapped))
        open.isEnabled = canOpen && row.error == nil

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: Self.nameColumnWidth).isActive = true

        let stack = NSStackView(views: [handle, icon, text, spacer, name, open])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.setCustomSpacing(12, after: spacer)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func beginEditingName() { name.beginEditing() }

    @objc private func toggled(_ sender: NSButton) { onEnabled(sender.state == .on) }
    @objc private func openTapped() { onOpen() }
}

/// A row's custom-name column: the name in semibold (or a quiet "Add a name"),
/// with "Click to edit" under it. Clicking turns the name into a text field:
/// Return or clicking away commits, Escape cancels, and an empty name clears it.
final class SlotNameView: NSView, NSTextFieldDelegate {
    private let customName: String?
    private let onBeginEditing: () -> Void
    private let onEndEditing: (String?) -> Void
    private let label: NSTextField
    private let hint = NSTextField(labelWithString: "Click to edit")
    private let field = NSTextField(string: "")
    private var cancelled = false
    private(set) var isEditing = false

    init(customName: String?, onBeginEditing: @escaping () -> Void, onEndEditing: @escaping (String?) -> Void) {
        self.customName = customName
        self.onBeginEditing = onBeginEditing
        self.onEndEditing = onEndEditing
        label = NSTextField(labelWithString: customName ?? "Add a name")
        super.init(frame: .zero)

        label.font = customName == nil ? .systemFont(ofSize: NSFont.systemFontSize)
                                       : .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        label.textColor = customName == nil ? .tertiaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let customName { label.toolTip = customName }

        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        hint.textColor = .tertiaryLabelColor

        field.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        field.placeholderString = "Add a name"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.isHidden = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label, field, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        toolTip = "Click to give this effect a name of your own"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Clicks land here, not on the labels inside, and a click edits even when the
    // window is not yet key.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isEditing else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard !isEditing else { return }
        // Commit any other row's edit first.
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        onBeginEditing()
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        cancelled = false
        field.stringValue = customName ?? ""
        label.isHidden = true
        field.isHidden = false
        hint.stringValue = "Return to save · Esc to cancel"
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelled = true
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Ends the edit however it happens: Return, Escape, Tab, a click elsewhere or
    /// the window losing focus.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        label.isHidden = false
        hint.stringValue = "Click to edit"
        onEndEditing(cancelled ? nil : field.stringValue)
    }
}
