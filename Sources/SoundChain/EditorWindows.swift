// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import AudioToolbox
import CoreAudioKit

/// One floating panel per plugin editor. A plugin with no UI of its own gets
/// Apple's generic parameter view. Main thread.
///
/// Closing a panel only hides it: the AUv2 bridge hands out a plugin's own view
/// controller once per instance (later requests return nil), and moving that view
/// into a new window crashes. So each slot's panel lives until the slot is removed.
final class EditorWindows: NSObject, NSWindowDelegate {
    var onClose: (UUID) -> Void = { _ in }

    private var panels: [UUID: NSPanel] = [:]
    private var pending: Set<UUID> = []

    /// Slots whose editor is currently on screen.
    var openSlotIDs: [UUID] { panels.filter { $0.value.isVisible }.map(\.key) }

    func open(slotID: UUID, title: String, unit: AUAudioUnit) {
        if let panel = panels[slotID] {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard pending.insert(slotID).inserted else { return }
        unit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(slotID)
                self.present(slotID: slotID, title: title, controller: controller ?? Self.genericView(for: unit))
            }
        }
    }

    /// Destroys a slot's panel for good (the slot was removed).
    func close(slotID: UUID) {
        guard let panel = panels.removeValue(forKey: slotID) else { return }
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    /// Hides every visible editor, reporting each through `onClose` (used at quit).
    func closeAll() {
        for (id, panel) in panels where panel.isVisible {
            onClose(id)
            panel.orderOut(nil)
        }
    }

    private static func genericView(for unit: AUAudioUnit) -> NSViewController {
        let generic = AUGenericViewController()
        generic.auAudioUnit = unit
        return generic
    }

    private func present(slotID: UUID, title: String, controller: NSViewController) {
        var size = controller.preferredContentSize
        if size.width < 50 || size.height < 50 { size = controller.view.frame.size }
        if size.width < 50 || size.height < 50 { size = NSSize(width: 600, height: 400) }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controller
        panel.setContentSize(size)
        panel.delegate = self
        panel.center()
        panels[slotID] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The close button hides the panel instead of closing it (see the type comment).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = panels.first(where: { $0.value === sender })?.key else { return true }
        onClose(id)
        sender.orderOut(nil)
        return false
    }
}
