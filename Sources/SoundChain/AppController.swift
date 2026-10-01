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
    /// Once a minute, in her turn with the other animated mascots, Carol runs
    /// on the spot for a second. `runTime` is seconds into the run, nil at rest.
    private var minuteCue: MinuteCue!
    private var runTime: TimeInterval?
    private lazy var runAnimation = IconAnimation(duration: CharacterIcon.caterpillarRunDuration, frame: { [weak self] t in
        self?.runTime = t
        self?.refreshIcon()
    }, completion: { [weak self] in
        self?.runTime = nil
        self?.refreshIcon()
    })
    private let store = ChainStore(url: ChainStore.defaultURL())
    private let crashGuard = CrashGuard(store: UserDefaults.standard)
    private let blame = CrashBlame(directory: ChainStore.defaultURL().deletingLastPathComponent())
    /// Effects pinned to the top of the Add picker (name prefixes). Override with
    /// `defaults write com.nicholaspsmith.SoundChain PinnedEffects -array …`.
    static let defaultPins = ["Pro-Q", "Pro-L 2", "Nectar 3"]
    static let pinsKey = "PinnedEffects"
    private var pins: [String] { UserDefaults.standard.stringArray(forKey: Self.pinsKey) ?? Self.defaultPins }
    /// Slots whose editor is being built, with the component to blame if that crashes.
    private var editorsOpening: [UUID: ComponentID] = [:]
    private let runner = ChainRunner()
    private let uad = UADHardware()
    private let bluetooth = BluetoothReconnect()
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
        let blamed = blame.recordLaunch(lastExitUnclean: crashGuard.lastExitWasUnclean)
        func names(_ ids: [ComponentID]) -> String {
            ids.map { id in chain.slots.first { $0.component == id }?.name ?? id.fourCC }.joined(separator: ", ")
        }
        if !blamed.badState.isEmpty {
            // It crashed while restoring saved settings: drop the settings, keep the plugin.
            for slot in chain.slots where blamed.badState.contains(slot.component) { chain.setState(nil, id: slot.id) }
            save()
            notice = "Reset \(names(blamed.badState))'s settings after they crashed SoundChain"
        }
        if !blamed.disabled.isEmpty {
            // The crash-loop count is left alone: if this blame was wrong, two strikes
            // still start SoundChain bypassed.
            notice = "Disabled \(names(blamed.disabled)) after it crashed SoundChain"
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
        minuteCue = MinuteCue { [weak self] in self?.runAnimation.start() }
        minuteCue.start()

        installEditMenu()
        runner.onChange = { [weak self] in self?.chainDidChange() }
        runner.isDisabled = { [blame] in blame.isDisabled($0) }
        runner.willStep = { [blame] id, step in blame.begin(id, step: step) }
        runner.didStep = { [blame] id, step in blame.end(id, step: step) }
        engine.onFormat = { [weak self] format in self?.runner.setFormat(format) }
        engine.onStateChange = { [weak self] _ in self?.refreshIcon() }
        runner.isSuspended = { [uad] slot in !uad.isPresent && UADCheck.needsHardware(slot) }
        uad.onChange = { [weak self] in self?.uadHardwareChanged() }
        uad.start()
        bluetooth.onFinish = { [weak self] result in
            self?.notice = result
            self?.refreshIcon()
        }
        runner.sync(to: chain)
        startAudio()
        editors.onClose = { [weak self] id in self?.captureState(id) }
        editors.onPresented = { [weak self] id in
            // Some plugins crash on their own threads just after their view appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, let component = self.editorsOpening.removeValue(forKey: id) else { return }
                self.blame.end(component, step: .editor)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.closeAll(notify: false)
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
        // A step that never finished (a plugin that never answered) must not be blamed
        // for some later, unrelated crash.
        blame.expire(olderThan: CrashBlame.markerLifetime)
        editorsOpening = editorsOpening.filter { _, component in
            blame.isInProgress(component, step: .editor)
        }
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
        if !editors.hasPanel(id), editorsOpening[id] == nil {
            editorsOpening[id] = slot.component
            blame.begin(slot.component, step: .editor)
        }
        editors.open(slotID: id, title: "\(slot.name) — \(slot.manufacturer)", unit: plugin.unit)
    }

    /// Reads a plugin's settings off the main thread, then stores them (saving only
    /// if they changed). At most one capture per plugin is in flight, so a plugin that
    /// stops answering cannot pile up work.
    private func captureState(_ id: UUID) {
        guard let plugin = runner.plugin(for: id) else { return }
        // In-process plugins are read here, on the main thread, like every other call
        // into them (prepare, editors), so nothing touches one instance concurrently.
        // Out-of-process ones answer over XPC, which can stall, so they go off main.
        guard plugin.isOutOfProcess else {
            if let data = plugin.captureState(), chain.setState(data, id: id) { save() }
            return
        }
        guard capturesInFlight.insert(id).inserted else { return }
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
        guard plugin.isOutOfProcess else { return plugin.captureState() }
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

    /// An Apollo or UAD-2 card came or went. On loss, the UAD-2 plugins leave the
    /// chain before anything else touches them: their editors close without reading
    /// settings (the last saved ones are kept) and the runner releases them. On
    /// return, `sync` loads them again with those settings.
    private func uadHardwareChanged() {
        if !uad.isPresent {
            for slot in chain.slots where UADCheck.needsHardware(slot) { editors.close(slotID: slot.id) }
        }
        runner.sync(to: chain)
        chainDidChange()
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
        if uadWarning != nil { return .error }
        if case .running(_, _?, _, _) = engine.state { return .error }
        return chain.masterBypass ? .bypassed : .processing
    }

    private var uadWarning: String? { UADCheck.warning(chain: chain, hardwarePresent: uad.isPresent) }

    private func refreshIcon() {
        let state: CaterpillarState
        switch health {
        case .processing: state = .processing
        case .bypassed: state = .bypassed
        case .error: state = .error
        }
        controller?.setIcon(CharacterIcon.caterpillar(effects: runner.activeCount, state: state, running: runTime))
    }

    /// The menu's status block: output device (and a warning if it is virtual), what
    /// is running, and the format.
    private var statusLines: [String] {
        if permissionDenied { return ["System audio recording isn't allowed"] }
        switch engine.state {
        case .stopped:
            return ["Starting…"]
        case .failed(let why):
            return [why]
        case .running(let device, let warning, let rate, let frames):
            let count = runner.activeCount
            let what = chain.masterBypass ? "Bypassed" : "\(count) effect\(count == 1 ? "" : "s") running"
            let khz = rate.truncatingRemainder(dividingBy: 1000) == 0
                ? "\(Int(rate / 1000))" : String(format: "%.1f", rate / 1000)
            return [device] + (warning.map { [$0] } ?? []) + [what, "\(khz) kHz · \(frames) frames"]
        }
    }

    /// Menu lines longer than this are cut short (full text in the tooltip), so a
    /// long device name or error cannot stretch the whole menu.
    static let menuLineLimit = 34

    // MARK: Menu

    private func buildMenu(_ menu: NSMenu) {
        statusLines.forEach { menu.addItem(disabled($0)) }
        if let notice { menu.addItem(disabled(notice)) }
        for error in slotErrors { menu.addItem(disabled(error)) }
        if let uadWarning { menu.addItem(disabled(uadWarning)) }
        menu.addItem(.separator())

        let chainItem = item("Audio Chain…", #selector(editChain), key: "c")
        chainItem.keyEquivalentModifierMask = [.control]
        menu.addItem(chainItem)
        if permissionDenied {
            menu.addItem(item("Grant System Audio Recording…", #selector(grantPermission)))
        }
        if permissionDenied || engine.state.isFailed {
            menu.addItem(item("Retry", #selector(retry)))
        }
        if let target = BluetoothReconnect.currentTarget() {
            let reconnect = item(bluetooth.inProgress ? "Reconnecting \(target.name)…" : "Reconnect \(target.name)",
                                 #selector(reconnectBluetooth))
            reconnect.isEnabled = !bluetooth.inProgress
            reconnect.toolTip = "For when headphones go silent. Saves recent Bluetooth logs to ~/Library/Logs/SoundChain first."
            menu.addItem(reconnect)
        }
        menu.addItem(.separator())

        let bypass = item("Bypass", #selector(toggleBypass))
        bypass.state = chain.masterBypass ? .on : .off
        menu.addItem(bypass)
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
        let short = title.count > Self.menuLineLimit ? String(title.prefix(Self.menuLineLimit - 1)) + "…" : title
        let item = NSMenuItem(title: short, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if short != title { item.toolTip = title }
        return item
    }

    /// A menu-bar app has no menu bar of its own, so nothing routes ⌘A/⌘C/⌘V/⌘X/⌘Z to
    /// text fields (the Add picker's search). An invisible main menu with the
    /// standard Edit items restores them while SoundChain's windows are active.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "SoundChain", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func editChain() {
        if chainWindow == nil { chainWindow = makeChainWindow() }
        chainWindow?.present()
    }

    private func makeChainWindow() -> ChainWindowController {
        let window = ChainWindowController()
        window.rows = { [unowned self] in
            let idle = Set(UADCheck.idleSlots(in: self.chain, hardwarePresent: self.uad.isPresent).map(\.id))
            return self.chain.slots.map { slot in
                ChainWindowController.Row(slot: slot, error: self.runner.error(for: slot.id)
                                          ?? (idle.contains(slot.id) ? UADCheck.rowNote : nil))
            }
        }
        window.catalog = { [unowned self] in
            ComponentScanner.effects(failures: self.runner.componentFailures, disabled: self.blame.disabled)
        }
        window.pinned = { [unowned self] in self.pins }
        window.onReenable = { [unowned self] entry in
            self.blame.enable(entry.component)
            self.runner.forgetDisabled(entry.component)
            self.runner.sync(to: self.chain)
        }
        window.onTogglePin = { [unowned self] entry in
            UserDefaults.standard.set(PinList.toggle(entry.name, in: self.pins), forKey: Self.pinsKey)
        }
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
        runner.clearErrors()
        runner.sync(to: chain)
        startAudio()
    }

    @objc private func toggleLogin() { LoginItem.toggle() }

    @objc private func reconnectBluetooth() {
        guard let target = BluetoothReconnect.currentTarget() else { return }
        notice = nil
        bluetooth.reconnect(target)
    }
}

@available(macOS 14.2, *)
private extension TapEngine.State {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// Carries a capture result from the capture queue back to a waiting thread.
private final class StateBox: @unchecked Sendable {
    var data: Data?
}
