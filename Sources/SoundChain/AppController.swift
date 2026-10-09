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
    /// The status block of the menu last built, refreshed in place while it is open.
    private var statusRows: [NSMenuItem] = []
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
    private let exclusive = BoseExclusive()
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
    /// The last slot copied with ⌘C. It also goes on the general pasteboard (so it
    /// outlives the window and the app); this copy covers a pasteboard that refused
    /// the write, and only while nothing else has been copied since.
    private var copiedSlot: SlotCopy?
    private var copiedChangeCount: Int?
    private static let slotPasteboardType = NSPasteboard.PasteboardType(SlotCopy.pasteboardType)
    /// Set when the chain file exists but could not be read or moved aside: saving
    /// would overwrite the user's chain, so nothing is saved this session.
    private var saveBlocked = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let startBypassed = crashGuard.recordLaunch()
        let loaded = store.load()
        chain = loaded.chain
        if let backup = loaded.corruptBackup {
            notice = "The chain file was unreadable; it was moved to \(backup.lastPathComponent)"
        } else if loaded.mustNotSave {
            saveBlocked = true
            notice = "Couldn't read the chain file, so changes won't be saved: \(loaded.readError ?? "")"
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
        engine.onStateChange = { [weak self] _ in
            self?.refreshIcon()
            self?.exclusive.outputChanged()
        }
        runner.isSuspended = { [uad] slot in !uad.isPresent && UADCheck.needsHardware(slot) }
        uad.onChange = { [weak self] in self?.uadHardwareChanged() }
        uad.start()
        bluetooth.onFinish = { [weak self] result in
            self?.notice = result
            self?.refreshIcon()
            self?.exclusive.outputChanged()
        }
        exclusive.isBusy = { [bluetooth] in bluetooth.inProgress }
        exclusive.onChange = { [weak self] in self?.refreshIcon() }
        exclusive.outputChanged()
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
        exclusive.stop()
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
        // Permission granted in System Settings while we were refused: start now,
        // without waiting for Retry.
        if permissionDenied, PermissionAdvice.shouldStart(denied: true, now: AudioPermission.status()) {
            notice = nil
            startAudio()
        }
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
        editors.open(slotID: id, title: Self.editorTitle(slot), unit: plugin.unit)
    }

    /// "Pitch Down — AUPitch" for a named effect, "AUPitch — Apple" otherwise.
    private static func editorTitle(_ slot: ChainSlot) -> String {
        "\(slot.displayName) — \(slot.customName == nil ? slot.manufacturer : slot.name)"
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

    /// Calls `done` on the main thread with a slot's current settings: read from its
    /// running plugin (and stored, so the original's saved settings are fresh too),
    /// or its saved settings when it is not loaded or does not answer within
    /// `quitCaptureTimeout`. Duplicate and Copy use this, because the saved state
    /// can be up to `editorCaptureInterval` old while an editor is open.
    private func withLiveState(of id: UUID, _ done: @escaping (Data?) -> Void) {
        guard let plugin = runner.plugin(for: id) else { done(chain.slot(id: id)?.state); return }
        guard plugin.isOutOfProcess else {
            if let data = plugin.captureState(), chain.setState(data, id: id) { save() }
            done(chain.slot(id: id)?.state)
            return
        }
        var finished = false
        let finish = { [weak self] (data: Data?) in
            guard !finished, let self else { return }
            finished = true
            if let data, self.chain.setState(data, id: id) { self.save() }
            done(data ?? self.chain.slot(id: id)?.state)
        }
        captureQueue.async {
            let data = plugin.captureState()
            DispatchQueue.main.async { finish(data) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitCaptureTimeout) { finish(nil) }
    }

    private func copySlot(_ copy: SlotCopy) {
        copiedSlot = copy
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(copy.encoded(), forType: Self.slotPasteboardType)
        copiedChangeCount = board.changeCount
    }

    /// Checks the pasteboard's types only (reading its data is for an actual paste).
    private var hasSlotToPaste: Bool {
        let board = NSPasteboard.general
        if board.types?.contains(Self.slotPasteboardType) == true { return true }
        return copiedSlot != nil && board.changeCount == copiedChangeCount
    }

    private func slotToPaste() -> SlotCopy? {
        let board = NSPasteboard.general
        if let data = board.data(forType: Self.slotPasteboardType), let copy = SlotCopy(encoded: data) { return copy }
        return board.changeCount == copiedChangeCount ? copiedSlot : nil
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
        guard !saveBlocked else { return }
        do {
            try store.save(chain)
        } catch {
            notice = "Couldn't save the chain: \(error.localizedDescription)"
        }
    }

    // MARK: Status and icon

    private enum Health { case processing, bypassed, error }

    private var slotErrors: [String] {
        chain.slots.compactMap { slot in runner.error(for: slot.id).map { "\(slot.displayName): \($0)" } }
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
        controller?.setIcon(CharacterIcon.caterpillar(effects: runner.activeCount, state: state, running: runTime,
                                                      headphones: exclusive.isEnabled))
        refreshStatusRows()
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
        statusRows = statusLines.map(disabled)
        statusRows.forEach(menu.addItem)
        if let notice { menu.addItem(disabled(notice)) }
        if let kept = exclusive.statusLine { menu.addItem(disabled(kept)) }
        for error in slotErrors { menu.addItem(disabled(error)) }
        if let uadWarning { menu.addItem(disabled(uadWarning)) }
        menu.addItem(.separator())

        let chainItem = item("Audio Chain…", #selector(editChain), key: "c")
        chainItem.keyEquivalentModifierMask = [.control]
        menu.addItem(chainItem)
        if PermissionAdvice.offersGrant(denied: permissionDenied, tapFailed: engine.state.isFailed,
                                        status: AudioPermission.status()) {
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
        // Carol wears her headphones while this is on, and round her neck while it is off.
        menu.addItem(ToggleMenuItem.make(
            title: "Keep Headphones to This Mac", isOn: exclusive.isEnabled,
            toolTip: "Bose headphones only. While they are the output, any other device connected to them "
                + "(your phone) is disconnected, now and every \(Int(BoseExclusive.interval)) seconds, "
                + "so the radio is not shared and the sound stays clean."
        ) { [weak self] on in
            self?.exclusive.isEnabled = on
            self?.refreshIcon()
        })
        menu.addItem(.separator())

        // The chain itself, in order: a tick means the effect is on. Clicking
        // one switches it on or off, as its checkbox in Audio Chain… does, and
        // the menu stays open so several can be switched in one go.
        if chain.slots.isEmpty {
            menu.addItem(disabled("No effects in the chain"))
        } else {
            for slot in chain.slots {
                let id = slot.id
                menu.addItem(ToggleMenuItem.make(title: slot.displayName, isOn: !slot.bypassed,
                                                 toolTip: "\(slot.name) — \(slot.manufacturer)") { [weak self] on in
                    self?.setSlot(id, on: on)
                })
            }
        }
        menu.addItem(.separator())

        menu.addItem(ToggleMenuItem.make(title: "Bypass", isOn: chain.masterBypass) { [weak self] on in
            self?.setBypass(on)
        })
        // Settings ▸ holds only the shared rows (Start at Login, Version):
        // everything SoundChain itself offers is a control used day to day.
        SettingsMenu.addFooter(to: menu, appName: "SoundChain")
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        setLine(item, title)
        return item
    }

    private func setLine(_ item: NSMenuItem, _ title: String) {
        let short = title.count > Self.menuLineLimit ? String(title.prefix(Self.menuLineLimit - 1)) + "…" : title
        item.title = short
        item.toolTip = short != title ? title : nil
    }

    /// Brings the open menu's status block ("2 effects running", "Bypassed")
    /// up to date after a tick, since ticking no longer closes the menu.
    private func refreshStatusRows() {
        let lines = statusLines
        guard lines.count == statusRows.count else { return }
        zip(statusRows, lines).forEach { setLine($0, $1) }
    }

    /// A menu-bar app has no menu bar of its own, so nothing routes ⌘A/⌘C/⌘V/⌘X/⌘Z to
    /// text fields (the Add picker's search), or ⌘C/⌘V/⌘D to the chain window's rows. An invisible main menu with the
    /// standard Edit items restores them while SoundChain's windows are active.
    /// It also carries the chain window's Duplicate (⌘D) and Rename (⌘R).
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        // The chain window's Duplicate (its copy:/paste: are the Copy and Paste above).
        edit.addItem(NSMenuItem(title: "Duplicate", action: #selector(ChainWindowController.duplicateSlot(_:)),
                                keyEquivalent: "d"))
        edit.addItem(NSMenuItem(title: "Rename", action: #selector(ChainWindowController.renameSlot(_:)),
                                keyEquivalent: "r"))
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
            // An editor still being built for it never appears; stop blaming it.
            if let component = self.editorsOpening.removeValue(forKey: id) { self.blame.end(component, step: .editor) }
            self.mutate { $0.remove(id: id) }
        }
        window.onAdd = { [unowned self] entry in
            self.mutate { $0.add(component: entry.component, name: entry.name, manufacturer: entry.manufacturer) }
        }
        window.onDuplicate = { [unowned self] id, done in
            self.withLiveState(of: id) { state in
                var added: ChainSlot?
                self.mutate { added = $0.duplicate(id: id, liveState: state) }
                done(added?.id)
            }
        }
        window.onCopy = { [unowned self] id in
            self.withLiveState(of: id) { state in
                guard let slot = self.chain.slot(id: id) else { return }
                self.copySlot(SlotCopy(slot, liveState: state))
            }
        }
        window.onPaste = { [unowned self] below in
            guard let copy = self.slotToPaste() else { return nil }
            var added: ChainSlot?
            self.mutate { added = $0.insert(copy, below: below) }
            return added?.id
        }
        window.canPaste = { [unowned self] in self.hasSlotToPaste }
        window.onRename = { [unowned self] id, name in
            guard self.chain.setCustomName(name, id: id) else { return }
            self.save()
            if let slot = self.chain.slot(id: id) { self.editors.setTitle(Self.editorTitle(slot), slotID: id) }
        }
        window.canOpen = true
        window.onOpen = { [unowned self] id in self.openEditor(id) }
        return window
    }

    private func setSlot(_ id: UUID, on: Bool) {
        guard chain.slots.contains(where: { $0.id == id }) else { return }
        mutate { $0.setBypassed(!on, id: id) }
        chainWindow?.reload()
        refreshIcon()
        refreshStatusRows()
    }

    private func setBypass(_ on: Bool) {
        notice = nil
        mutate { $0.masterBypass = on }
        refreshIcon()
        refreshStatusRows()
    }

    @objc private func grantPermission() { AudioPermission.openSettings() }

    @objc private func retry() {
        notice = nil
        runner.clearErrors()
        runner.sync(to: chain)
        startAudio()
    }

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
