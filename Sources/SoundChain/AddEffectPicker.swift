// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore

/// A search field over the installed effects, grouped by manufacturer. Return or a
/// double-click picks; ↑/↓ move the selection from the search field. Plugins that
/// failed to load this session are shown in red and cannot be picked.
final class AddEffectViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Item {
        case header(String)
        case entry(CatalogEntry)
    }

    private let entries: [CatalogEntry]
    private let pinned: [String]
    private let onPick: (CatalogEntry) -> Void
    private var items: [Item] = []
    private let search = NSSearchField()
    private let table = NSTableView()

    init(entries: [CatalogEntry], pinned: [String] = [], onPick: @escaping (CatalogEntry) -> Void) {
        self.entries = entries
        self.pinned = pinned
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        search.placeholderString = "Search effects"
        search.delegate = self

        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 420)
        view = stack
        preferredContentSize = stack.frame.size
        reloadItems()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    private func reloadItems() {
        items = PluginCatalog.groups(entries, search: search.stringValue, pinned: pinned).flatMap { group in
            [Item.header(group.manufacturer)] + group.entries.map(Item.entry)
        }
        table.reloadData()
        if let first = items.indices.first(where: isPickable) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
    }

    private func isPickable(_ row: Int) -> Bool {
        guard items.indices.contains(row), case .entry(let entry) = items[row] else { return false }
        return entry.loadError == nil && !entry.disabled
    }

    private func pick(row: Int) {
        guard isPickable(row), case .entry(let entry) = items[row] else { return }
        onPick(entry)
    }

    private func moveSelection(_ step: Int) {
        var row = table.selectedRow
        repeat { row += step } while items.indices.contains(row) && !isPickable(row)
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() { pick(row: table.clickedRow) }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) { reloadItems() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): pick(row: table.selectedRow); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        default: return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isPickable(row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let manufacturer):
            let label = NSTextField(labelWithString: manufacturer)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            return label
        case .entry(let entry):
            let label: NSTextField
            if entry.disabled {
                label = NSTextField(labelWithString: "\(entry.name) — \(entry.manufacturer)")
                label.textColor = .disabledControlTextColor
            } else {
                label = NSTextField(labelWithString: entry.loadError.map { "\(entry.name) — \($0)" } ?? entry.name)
                label.textColor = entry.loadError == nil ? .labelColor : .systemRed
            }
            label.lineBreakMode = .byTruncatingTail
            let icon = PluginIcons.view(for: entry.component, size: 16)
            if entry.disabled || entry.loadError != nil { icon.alphaValue = 0.4 }
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }
    }
}
