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
    /// Called once a newly built editor is on screen.
    var onPresented: (UUID) -> Void = { _ in }

    private var panels: [UUID: NSPanel] = [:]
    /// Editors being built: slot → the request building it.
    private var pending: [UUID: UUID] = [:]

    func hasPanel(_ slotID: UUID) -> Bool { panels[slotID] != nil }

    /// Slots whose editor is currently on screen.
    var openSlotIDs: [UUID] { panels.filter { $0.value.isVisible }.map(\.key) }

    func open(slotID: UUID, title: String, unit: AUAudioUnit) {
        if let panel = panels[slotID] {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard pending[slotID] == nil else { return }
        let request = UUID()
        pending[slotID] = request
        unit.requestViewController { [weak self] controller in
            DispatchQueue.main.async {
                // Not pending any more: the slot was closed (removed) while its view
                // was being built, so there is nothing to show it for.
                guard let self, self.pending[slotID] == request else { return }
                self.pending[slotID] = nil
                self.present(slotID: slotID, title: title, controller: controller ?? Self.genericView(for: unit))
            }
        }
    }

    /// Destroys a slot's panel for good (the slot was removed), and drops an editor
    /// still being built for it, so it never appears.
    func close(slotID: UUID) {
        pending[slotID] = nil
        guard let panel = panels.removeValue(forKey: slotID) else { return }
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    /// Hides every visible editor. At quit, pass `notify: false`: the app captures
    /// every plugin's settings itself, so reporting each close would read them twice.
    func closeAll(notify: Bool = true) {
        for (id, panel) in panels where panel.isVisible {
            if notify { onClose(id) }
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
        onPresented(slotID)
    }

    /// The close button hides the panel instead of closing it (see the type comment).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = panels.first(where: { $0.value === sender })?.key else { return true }
        onClose(id)
        sender.orderOut(nil)
        return false
    }
}
