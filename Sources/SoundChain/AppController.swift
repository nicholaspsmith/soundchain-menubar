// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import AppKit
import SoundChainCore
import StatusItemKit

@available(macOS 14.2, *)
final class AppController: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController!
    private var yieldClient: YieldClient!
    private let store = ChainStore(url: ChainStore.defaultURL())
    private let crashGuard = CrashGuard(store: UserDefaults.standard)
    private let runner = ChainRunner()
    private lazy var engine = TapEngine(source: runner.source)
    private(set) var chain = Chain()
    /// A one-off message for the menu (corrupt chain file, crash-loop bypass, save failure).
    private var notice: String?
    private var permissionDenied = false
    private var chainWindow: ChainWindowController?
    private let editors = EditorWindows()
    private var lastEditorCapture = Date()
    static let editorCaptureInterval: TimeInterval = 5
    /// How long quitting waits for each plugin's settings before giving up on it.
    static let quitCaptureTimeout: TimeInterval = 1
    /// Reading `fullState` of an out-of-process plugin is a synchronous XPC call; a
    /// plugin busy with its own UI (an authorization screen, say) can take seconds or
    /// wait on us. So captures never run on the main thread.
    private let captureQueue = DispatchQueue(label: "com.nicholaspsmith.SoundChain.capture",
                                             qos: .utility, attributes: .concurrent)
    private var capturesInFlight: Set<UUID> = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let startBypassed = crashGuard.recordLaunch()
        let loaded = store.load()
        chain = loaded.chain
        if let backup = loaded.corruptBackup {
            notice = "The chain file was unreadable; it was moved to \(backup.lastPathComponent)"
        }
        if startBypassed {
            chain.masterBypass = true
            notice = "Started bypassed after two crashes in a row"
            save()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.crashGuard.markStable() }

        controller = StatusItemController(
            pollInterval: 1,
            onPoll: { [weak self] in self?.tick() },
            onBuildMenu: { [weak self] menu in self?.buildMenu(menu) }
        )
        controller.start()
        yieldClient = YieldClient(item: controller)
        yieldClient.start()

        runner.onChange = { [weak self] in self?.chainDidChange() }
        engine.onFormat = { [weak self] format in self?.runner.setFormat(format) }
        engine.onStateChange = { [weak self] _ in self?.refreshIcon() }
        runner.sync(to: chain)
        startAudio()
        editors.onClose = { [weak self] id in self?.captureState(id) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.closeAll()
        for slot in chain.slots {
            if let data = captureStateBlocking(slot.id) { chain.setState(data, id: slot.id) }
        }
        save()
        engine.stop()
        crashGuard.recordCleanExit()
    }

    private func startAudio() {
        switch AudioPermission.status() {
        case .authorized:
            permissionDenied = false
            engine.start()
        case .denied:
            permissionDenied = true
            refreshIcon()
        case .unknown:
            AudioPermission.request { [weak self] granted in
                guard let self else { return }
                self.permissionDenied = !granted
                if granted { self.engine.start() } else { self.refreshIcon() }
            }
        }
    }

    private func tick() {
        runner.tick()
        if !editors.openSlotIDs.isEmpty,
           Date().timeIntervalSince(lastEditorCapture) >= Self.editorCaptureInterval {
            lastEditorCapture = Date()
            editors.openSlotIDs.forEach(captureState)
        }
        refreshIcon()
    }

    // MARK: Chain changes

    /// The single funnel for chain edits: apply, save, and re-sync the audio.
    func mutate(_ change: (inout Chain) -> Void) {
        change(&chain)
        save()
        runner.sync(to: chain)
    }

    private func openEditor(_ id: UUID) {
        guard let slot = chain.slot(id: id), let plugin = runner.plugin(for: id) else { return }
        editors.open(slotID: id, title: "\(slot.name) — \(slot.manufacturer)", unit: plugin.unit)
    }

    /// Reads a plugin's settings off the main thread, then stores them (saving only
    /// if they changed). At most one capture per plugin is in flight, so a plugin that
    /// stops answering cannot pile up work.
    private func captureState(_ id: UUID) {
        guard let plugin = runner.plugin(for: id), capturesInFlight.insert(id).inserted else { return }
        captureQueue.async { [weak self] in
            let data = plugin.captureState()
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturesInFlight.remove(id)
                if let data, self.chain.setState(data, id: id) { self.save() }
            }
        }
    }

    /// For quitting: waits up to `quitCaptureTimeout` for a plugin's settings.
    private func captureStateBlocking(_ id: UUID) -> Data? {
        guard let plugin = runner.plugin(for: id) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = StateBox()
        captureQueue.async {
            box.data = plugin.captureState()
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.quitCaptureTimeout) == .success else {
            NSLog("SoundChain: gave up waiting for settings from slot %@", id.uuidString)
            return nil
        }
        return box.data
    }

    private func chainDidChange() {
        refreshIcon()
        chainWindow?.reload()
    }

    private func save() {
        do {
            try store.save(chain)
        } catch {
            notice = "Couldn't save the chain: \(error.localizedDescription)"
        }
    }

    // MARK: Status and icon

    private enum Health { case processing, bypassed, error }

    private var slotErrors: [String] {
        chain.slots.compactMap { slot in runner.error(for: slot.id).map { "\(slot.name): \($0)" } }
    }

    private var health: Health {
        if permissionDenied { return .error }
        if case .failed = engine.state { return .error }
        if !slotErrors.isEmpty { return .error }
        return chain.masterBypass ? .bypassed : .processing
    }

    private func refreshIcon() {
        let color: NSColor
        switch health {
        case .processing: color = .systemGreen
        case .bypassed: color = .systemGray
        case .error: color = .systemRed
        }
        controller?.setIcon(MeterIcon.dot(color: color))
    }

    private var statusLine: String {
        if permissionDenied { return "System audio recording isn't allowed" }
        switch engine.state {
        case .stopped:
            return "Starting…"
        case .failed(let why):
            return why
        case .running(let device, let rate, let frames):
            let count = runner.activeCount
            let what = chain.masterBypass ? "bypassed" : "\(count) effect\(count == 1 ? "" : "s")"
            return "\(device) · \(what) · \(Int(rate / 1000)) kHz / \(frames)"
        }
    }

    // MARK: Menu

    private func buildMenu(_ menu: NSMenu) {
        menu.addItem(disabled(statusLine))
        if let notice { menu.addItem(disabled(notice)) }
        for error in slotErrors { menu.addItem(disabled(error)) }
        menu.addItem(.separator())

        let bypass = item("Bypass", #selector(toggleBypass), key: "b")
        bypass.state = chain.masterBypass ? .on : .off
        menu.addItem(bypass)
        menu.addItem(item("Edit Chain…", #selector(editChain), key: "e"))
        if permissionDenied {
            menu.addItem(item("Grant System Audio Recording…", #selector(grantPermission)))
        }
        if permissionDenied || engine.state.isFailed {
            menu.addItem(item("Retry", #selector(retry)))
        }
        menu.addItem(.separator())

        let login = item("Start at Login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(AppVersion.menuItem())
        menu.addItem(NSMenuItem(title: "Quit SoundChain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func editChain() {
        if chainWindow == nil { chainWindow = makeChainWindow() }
        chainWindow?.present()
    }

    private func makeChainWindow() -> ChainWindowController {
        let window = ChainWindowController()
        window.rows = { [unowned self] in
            self.chain.slots.map { ChainWindowController.Row(slot: $0, error: self.runner.error(for: $0.id)) }
        }
        window.catalog = { [unowned self] in ComponentScanner.effects(failures: self.runner.componentFailures) }
        window.onBypass = { [unowned self] id, bypassed in self.mutate { $0.setBypassed(bypassed, id: id) } }
        window.onMove = { [unowned self] from, to in self.mutate { $0.move(from: from, insertionIndex: to) } }
        window.onRemove = { [unowned self] id in
            self.editors.close(slotID: id)
            self.mutate { $0.remove(id: id) }
        }
        window.onAdd = { [unowned self] entry in
            self.mutate { $0.add(component: entry.component, name: entry.name, manufacturer: entry.manufacturer) }
        }
        window.canOpen = true
        window.onOpen = { [unowned self] id in self.openEditor(id) }
        return window
    }

    @objc private func toggleBypass() {
        notice = nil
        mutate { $0.masterBypass.toggle() }
    }

    @objc private func grantPermission() { AudioPermission.openSettings() }

    @objc private func retry() {
        notice = nil
        startAudio()
    }

    @objc private func toggleLogin() { LoginItem.toggle() }
}

@available(macOS 14.2, *)
private extension TapEngine.State {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// Carries a capture result from the capture queue back to a waiting thread.
private final class StateBox: @unchecked Sendable {
    var data: Data?
}
