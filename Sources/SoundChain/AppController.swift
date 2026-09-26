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
        // Task 11: editor wiring goes here.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Task 11: close editors here, before states are captured.
        for slot in chain.slots {
            if let data = runner.captureState(for: slot.id) { chain.setState(data, id: slot.id) }
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
        // Task 11: periodic editor state capture goes here.
        refreshIcon()
    }

    // MARK: Chain changes

    /// The single funnel for chain edits: apply, save, and re-sync the audio.
    func mutate(_ change: (inout Chain) -> Void) {
        change(&chain)
        save()
        runner.sync(to: chain)
    }

    private func chainDidChange() {
        refreshIcon()
        // Task 10: chain window reload goes here.
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
        // Task 10: "Edit Chain…" goes here.
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
