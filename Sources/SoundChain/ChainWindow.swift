// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore

/// The chain editor: a drag-to-reorder list of effects with bypass checkboxes and
/// Open buttons, plus Add…, – and Duplicate, and ⌘C/⌘V/⌘D on the selected row.
/// Holds no chain state; it asks `rows()` on reload.
///
/// ⌘C/⌘V/⌘D arrive as `copy:`/`paste:`/`duplicateSlot:` from the app's hidden Edit
/// menu: the table does not answer them, so they travel up the responder chain to
/// the window and on to this controller. A text field in the Add picker gets them
/// first, so typing there still copies and pastes text.
final class ChainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuItemValidation {
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
    /// False until editor windows exist (Task 11).
    var canOpen = false

    private static let dragType = NSPasteboard.PasteboardType("com.nicholaspsmith.SoundChain.row")
    private let table = NSTableView()
    private let removeButton = NSButton(title: "–", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    private var current: [Row] = []
    private var addPopover: NSPopover?
    /// After a removal, the row index to select next (so repeated – presses keep deleting).
    private var selectAfterRemove: Int?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SoundChain"
        window.minSize = NSSize(width: 360, height: 220)
        window.isReleasedWhenClosed = false
        super.init(window: window)
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
        let buttons = NSStackView(views: [addButton, removeButton, duplicateButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
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
                           onOpen: { [weak self] in self?.onOpen(id) })
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
        case #selector(copy(_:)), #selector(duplicateSlot(_:)): return selectedID != nil
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

/// One chain row: drag hint, enable checkbox with the plugin name, manufacturer or
/// error underneath (red), and an Open button.
final class SlotRowView: NSView {
    private let onEnabled: (Bool) -> Void
    private let onOpen: () -> Void

    init(row: ChainWindowController.Row, canOpen: Bool,
         onEnabled: @escaping (Bool) -> Void, onOpen: @escaping () -> Void) {
        self.onEnabled = onEnabled
        self.onOpen = onOpen
        super.init(frame: .zero)

        let handle = NSTextField(labelWithString: "≡")
        handle.textColor = .tertiaryLabelColor

        let check = NSButton(checkboxWithTitle: row.slot.name, target: self, action: #selector(toggled(_:)))
        check.state = row.slot.bypassed ? .off : .on

        let detail = NSTextField(labelWithString: row.error ?? row.slot.manufacturer)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = row.error == nil ? .secondaryLabelColor : .systemRed
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [check, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let icon = PluginIcons.view(for: row.slot.component, size: 26)
        icon.alphaValue = row.slot.bypassed || row.error != nil ? 0.45 : 1

        let open = NSButton(title: "Open", target: self, action: #selector(openTapped))
        open.isEnabled = canOpen && row.error == nil

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [handle, icon, text, spacer, open])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggled(_ sender: NSButton) { onEnabled(sender.state == .on) }
    @objc private func openTapped() { onOpen() }
}
