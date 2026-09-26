// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import AudioToolbox
import CoreAudioKit

/// One floating panel per open plugin editor. A plugin with no UI of its own gets
/// Apple's generic parameter view. Main thread.
final class EditorWindows: NSObject, NSWindowDelegate {
    var onClose: (UUID) -> Void = { _ in }

    private var panels: [UUID: NSPanel] = [:]
    private var pending: Set<UUID> = []

    var openSlotIDs: [UUID] { Array(panels.keys) }

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

    func close(slotID: UUID) { panels[slotID]?.close() }     // windowWillClose does the rest

    func closeAll() { Array(panels.values).forEach { $0.close() } }

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

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let id = panels.first(where: { $0.value === panel })?.key else { return }
        panels[id] = nil
        onClose(id)                          // capture state while the view still exists
        panel.contentViewController = nil
    }
}
