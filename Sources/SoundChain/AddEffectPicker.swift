// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore

/// A search field over the installed effects, grouped by manufacturer. Return or a
/// double-click picks; ↑/↓ move the selection from the search field. Plugins that
/// failed to load this session are shown in red and cannot be picked. Each row's pin
/// button (or right-click ▸ Pin/Unpin) moves an effect in or out of the Pinned group.
final class AddEffectViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSMenuDelegate {
    private enum Item {
        case header(String)
        case entry(CatalogEntry)
    }

    private let entries: [CatalogEntry]
    private let pins: () -> [String]
    private let onTogglePin: (CatalogEntry) -> Void
    private let onPick: (CatalogEntry) -> Void
    private var items: [Item] = []
    private let search = NSSearchField()
    private let table = NSTableView()

    init(entries: [CatalogEntry], pins: @escaping () -> [String] = { [] },
         onTogglePin: @escaping (CatalogEntry) -> Void = { _ in },
         onPick: @escaping (CatalogEntry) -> Void) {
        self.entries = entries
        self.pins = pins
        self.onTogglePin = onTogglePin
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.menu = {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }()
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

    private func reloadItems(keeping component: ComponentID? = nil) {
        items = PluginCatalog.groups(entries, search: search.stringValue, pinned: pins()).flatMap { group in
            [Item.header(group.manufacturer)] + group.entries.map(Item.entry)
        }
        table.reloadData()
        let kept = component.flatMap { id in
            items.firstIndex { if case .entry(let e) = $0 { return e.component == id } else { return false } }
        }
        if let row = kept ?? items.indices.first(where: isPickable) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    private func togglePin(row: Int) {
        guard items.indices.contains(row), case .entry(let entry) = items[row], !entry.disabled else { return }
        onTogglePin(entry)
        reloadItems(keeping: entry.component)
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard items.indices.contains(row), case .entry(let entry) = items[row], !entry.disabled else { return }
        let pinned = PinList.isPinned(entry.name, in: pins())
        let item = NSMenuItem(title: pinned ? "Unpin \(entry.name)" : "Pin \(entry.name)",
                              action: #selector(menuTogglePin(_:)), keyEquivalent: "")
        item.target = self
        item.tag = row
        menu.addItem(item)
    }

    @objc private func menuTogglePin(_ sender: NSMenuItem) { togglePin(row: sender.tag) }

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
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            var views: [NSView] = [icon, label, spacer]
            if !entry.disabled {
                let pinned = PinList.isPinned(entry.name, in: pins())
                let pin = ActionButton(symbol: pinned ? "pin.fill" : "pin",
                                       tip: pinned ? "Unpin" : "Pin to the top") { [weak self] in
                    self?.togglePin(row: row)
                }
                pin.contentTintColor = pinned ? .controlAccentColor : .tertiaryLabelColor
                views.append(pin)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 6
            return stack
        }
    }
}

/// A borderless SF Symbol button that runs a closure.
final class ActionButton: NSButton {
    private let handler: () -> Void

    init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        isBordered = false
        toolTip = tip
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
