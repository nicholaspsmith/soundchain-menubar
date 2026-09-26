# SoundChain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Menubarn menu-bar app that runs one global chain of Audio Unit effects over all macOS system audio.

**Architecture:** A Core Audio global process tap (excluding SoundChain itself, muting the originals) is wrapped with the current default output device in a private aggregate device. That device's IO proc copies the tapped audio into an immutable `RenderChain` snapshot, renders the AUs in order, and writes to the output. The main thread builds new snapshots on every chain edit and publishes them through one atomic pointer. Pure logic (model, persistence, catalog, crash guard, buffer mapping) lives in a tested `SoundChainCore` library.

**Tech Stack:** Swift 5.9 language mode (Swift 6.2 toolchain), SwiftPM, AppKit, CoreAudio (process taps, macOS 14.2+), AudioToolbox/AVFoundation (`AUAudioUnit`), CoreAudioKit (`AUGenericViewController`), StatusItemKit (sibling package), a tiny local C target for atomics, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-26-soundchain-design.md`

## Global Constraints

- Minimum macOS **14.2**: `Info.plist` `LSMinimumSystemVersion` = `14.2`; `Package.swift` `platforms: [.macOS(.v14)]`; every type using tap APIs is `@available(macOS 14.2, *)`.
- Repo: `~/Code/soundchain-menubar`. Local git only: **never push**, never create a GitHub repo.
- Dependencies: `.package(path: "../StatusItemKit")` only. No third-party packages. Atomics come from the local `CAtomics` C target.
- Bundle id `com.nicholaspsmith.SoundChain`; executable and display name `SoundChain`.
- Every Swift/C/shell source file starts with the MPL-2.0 header used across the Menubarn repos:
  ```
  // This Source Code Form is subject to the terms of the Mozilla Public
  // License, v. 2.0. If a copy of the MPL was not distributed with this
  // file, You can obtain one at https://mozilla.org/MPL/2.0/.
  //
  // Copyright (c) 2026 Nicholas Smith
  ```
  (use `#` instead of `//` in shell scripts). Code blocks below omit it for brevity; add it to each new file.
- Chain file: `~/Library/Application Support/SoundChain/chain.json`.
- AU only (AUv2 and AUv3). No VST3.
- Real-time rule: code called from the IO proc (`TapEngine.render`, `RenderChain.process`, `TapInput`, `ChannelMap`, `SampleGuard`, the pull block) never allocates, locks, logs, or does I/O.
- Requested device buffer: 512 frames. `RenderFormat.maxFrames` = max(4096, actual buffer size).
- Tests: XCTest, run with `swift test`. App bundle: `scripts/build-app.sh` (wraps `../StatusItemKit/scripts/make-app.sh`, which requires a `vX.Y.Z` tag).
- Do not launch Apollo Monitor or MacRecorder. Do not use sudo.
- Commit messages end with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **SoundChain tapping its own output (feedback loop).** If the own-process lookup fails or the exclusion doesn't work, the processed audio is re-captured and howls. Expected: the engine refuses to start with a clear error rather than tap itself. Pinned in Task 8 (`--taptest` prints the own process object and fails if it is missing; manual listen at low volume).
2. **Output device changes mid-playback** (AirPods connect, Scarlett unplugged). Expected: audio moves to the new default within about a second, never goes silent, never loops restarting. Pinned in Task 8 (`needsRestart` logic plus the manual device-switch step in `--taptest 20`).
3. **Saved plugin state that no longer restores** (plugin updated or file edited). Expected: the plugin loads with defaults, the slot and its other data survive. Pinned in Task 7 (self-test slot with garbage state).
4. **A buffer larger than the render capacity, or a malformed input list.** Expected: silence for that cycle, no crash or overrun. Pinned in Task 5 (`TapInput` over-capacity, empty and nil-data tests).
5. **System-audio permission denied.** Expected: red icon, a status line saying so, and a menu item that opens the right Settings pane; no silent failure. Pinned in Task 9 (manual permission-denied step).

---

## File Structure

```
soundchain-menubar/
  Package.swift
  .gitignore
  LICENSE                                  (copy of ../battery-time-menubar/LICENSE)
  README.md                                (Task 12)
  install.sh                               (Task 9)
  scripts/build-app.sh                     (Task 9)
  Resources/Info.plist                     (Task 9)
  docs/e2e-checklist.md                    (Task 12)
  Sources/CAtomics/include/sc_atomics.h    atomic pointer, per-stage flags, counter
  Sources/CAtomics/sc_atomics.c
  Sources/SoundChainCore/
    ChainModel.swift      ComponentID, ChainSlot, Chain (+ operations)
    ChainStore.swift      JSON load/save, corrupt-file recovery
    PluginCatalog.swift   CatalogEntry, CatalogGroup, grouping + search
    CrashGuard.swift      FlagStore, CrashGuard
    TapInput.swift        read the tap's stereo stream out of the aggregate's input list
    ChannelMap.swift      write stereo into any output layout; zero
    SampleGuard.swift     NaN/inf guard
  Sources/SoundChain/
    main.swift            entry: --login, --selftest, --taptest, app
    PluginHost.swift      ComponentID<->AudioComponentDescription, RenderFormat, PluginError, LoadedPlugin
    RenderChain.swift     immutable audio-thread snapshot
    SnapshotSource.swift  the atomic pointer the IO proc reads
    ChainRunner.swift     main-thread owner of plugins; builds/publishes/retires snapshots
    SelfTest.swift        --selftest
    AudioHW.swift         Core Audio property helpers, CoreAudioError
    AudioPermission.swift TCC preflight/request, open Settings
    TapEngine.swift       tap + private aggregate + IO proc + device listeners
    TapTest.swift         --taptest
    AppController.swift   app delegate: menu, icon, status, persistence, wiring
    ComponentScanner.swift installed effects -> [CatalogEntry]
    ChainWindow.swift     ChainWindowController + SlotRowView
    AddEffectPicker.swift AddEffectViewController (searchable popover)
    EditorWindows.swift   one NSPanel per open plugin editor
  Tests/SoundChainCoreTests/
    TestBuffers.swift, AtomicsTests.swift, ChainModelTests.swift, ChainStoreTests.swift,
    PluginCatalogTests.swift, CrashGuardTests.swift, TapInputTests.swift,
    ChannelMapTests.swift, SampleGuardTests.swift
```

---

### Task 1: Package scaffold, C atomics, chain model

**Files:**
- Create: `Package.swift`, `.gitignore`, `LICENSE`
- Create: `Sources/CAtomics/include/sc_atomics.h`, `Sources/CAtomics/sc_atomics.c`
- Create: `Sources/SoundChainCore/ChainModel.swift`
- Create: `Sources/SoundChain/main.swift` (placeholder, replaced in Task 6)
- Test: `Tests/SoundChainCoreTests/AtomicsTests.swift`, `Tests/SoundChainCoreTests/ChainModelTests.swift`

**Interfaces:**
- Produces (C, imported into Swift as `OpaquePointer` handles):
  `sc_atomic_ptr_create() -> OpaquePointer`, `sc_atomic_ptr_destroy(_:)`, `sc_atomic_ptr_load(_:) -> UnsafeMutableRawPointer?`, `sc_atomic_ptr_exchange(_:_:) -> UnsafeMutableRawPointer?`;
  `sc_flags_create(Int32) -> OpaquePointer`, `sc_flags_destroy(_:)`, `sc_flags_set(_:Int32)`, `sc_flags_get(_:Int32) -> Int32`;
  `sc_counter_create() -> OpaquePointer`, `sc_counter_destroy(_:)`, `sc_counter_increment(_:)`, `sc_counter_get(_:) -> Int64`.
- Produces (Swift, `SoundChainCore`):
  `struct ComponentID: Codable, Hashable, Sendable { var type, subtype, manufacturer: UInt32; init(type:subtype:manufacturer:); init?(_ type: String, _ subtype: String, _ manufacturer: String); var fourCC: String }`;
  `struct ChainSlot: Codable, Equatable, Identifiable, Sendable { var id: UUID; var component: ComponentID; var name: String; var manufacturer: String; var bypassed: Bool; var state: Data? }`;
  `struct Chain: Codable, Equatable, Sendable { static let currentVersion = 1; var version: Int; var masterBypass: Bool; var slots: [ChainSlot]; func slot(id:) -> ChainSlot?; mutating func add(component:name:manufacturer:) -> ChainSlot (discardable); remove(id:); move(from:insertionIndex:); setBypassed(_:id:); setState(_:id:) -> Bool (discardable) }`.

- [ ] **Step 1: Create the package skeleton**

`Package.swift`:
```swift
// swift-tools-version:5.9
// (MPL header)

import PackageDescription

let package = Package(
    name: "SoundChain",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SoundChain", targets: ["SoundChain"]),
        .library(name: "SoundChainCore", targets: ["SoundChainCore"]),
    ],
    dependencies: [
        .package(path: "../StatusItemKit"),
    ],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "SoundChainCore"),
        .executableTarget(
            name: "SoundChain",
            dependencies: [
                "SoundChainCore",
                "CAtomics",
                .product(name: "StatusItemKit", package: "StatusItemKit"),
            ]
        ),
        .testTarget(name: "SoundChainCoreTests", dependencies: ["SoundChainCore", "CAtomics"]),
    ]
)
```

`.gitignore`:
```
.DS_Store
.build/
build/
*.app
.swiftpm/
```

```bash
cd ~/Code/soundchain-menubar && cp ../battery-time-menubar/LICENSE LICENSE
```

`Sources/SoundChain/main.swift` (placeholder):
```swift
import Foundation

print("SoundChain: nothing to run yet.")
```

- [ ] **Step 2: Write the C atomics target**

`Sources/CAtomics/include/sc_atomics.h`:
```c
#ifndef SC_ATOMICS_H
#define SC_ATOMICS_H

#include <stdint.h>

#pragma clang assume_nonnull begin

/// A pointer-sized cell read by the audio thread and swapped by the main thread.
typedef struct sc_atomic_ptr sc_atomic_ptr;
sc_atomic_ptr *sc_atomic_ptr_create(void);
void sc_atomic_ptr_destroy(sc_atomic_ptr *cell);
void *_Nullable sc_atomic_ptr_load(sc_atomic_ptr *cell);
/// Stores `value` and returns the previous value.
void *_Nullable sc_atomic_ptr_exchange(sc_atomic_ptr *cell, void *_Nullable value);

/// A fixed array of 0/1 flags (one per render stage). Out-of-range indexes are ignored / read as 0.
typedef struct sc_flags sc_flags;
sc_flags *sc_flags_create(int32_t count);
void sc_flags_destroy(sc_flags *flags);
void sc_flags_set(sc_flags *flags, int32_t index);
int32_t sc_flags_get(sc_flags *flags, int32_t index);

/// A monotonically increasing counter.
typedef struct sc_counter sc_counter;
sc_counter *sc_counter_create(void);
void sc_counter_destroy(sc_counter *counter);
void sc_counter_increment(sc_counter *counter);
int64_t sc_counter_get(sc_counter *counter);

#pragma clang assume_nonnull end

#endif
```

`Sources/CAtomics/sc_atomics.c`:
```c
#include "sc_atomics.h"
#include <stdatomic.h>
#include <stdlib.h>

struct sc_atomic_ptr { _Atomic(void *) value; };

sc_atomic_ptr *sc_atomic_ptr_create(void) {
    sc_atomic_ptr *cell = malloc(sizeof *cell);
    atomic_init(&cell->value, NULL);
    return cell;
}
void sc_atomic_ptr_destroy(sc_atomic_ptr *cell) { free(cell); }
void *sc_atomic_ptr_load(sc_atomic_ptr *cell) {
    return atomic_load_explicit(&cell->value, memory_order_acquire);
}
void *sc_atomic_ptr_exchange(sc_atomic_ptr *cell, void *value) {
    return atomic_exchange_explicit(&cell->value, value, memory_order_acq_rel);
}

struct sc_flags { int32_t count; _Atomic(int32_t) values[]; };

sc_flags *sc_flags_create(int32_t count) {
    if (count < 0) count = 0;
    sc_flags *flags = malloc(sizeof *flags + sizeof(_Atomic(int32_t)) * (size_t)count);
    flags->count = count;
    for (int32_t i = 0; i < count; i++) atomic_init(&flags->values[i], 0);
    return flags;
}
void sc_flags_destroy(sc_flags *flags) { free(flags); }
void sc_flags_set(sc_flags *flags, int32_t index) {
    if (index < 0 || index >= flags->count) return;
    atomic_store_explicit(&flags->values[index], 1, memory_order_release);
}
int32_t sc_flags_get(sc_flags *flags, int32_t index) {
    if (index < 0 || index >= flags->count) return 0;
    return atomic_load_explicit(&flags->values[index], memory_order_acquire);
}

struct sc_counter { _Atomic(int64_t) value; };

sc_counter *sc_counter_create(void) {
    sc_counter *counter = malloc(sizeof *counter);
    atomic_init(&counter->value, 0);
    return counter;
}
void sc_counter_destroy(sc_counter *counter) { free(counter); }
void sc_counter_increment(sc_counter *counter) {
    atomic_fetch_add_explicit(&counter->value, 1, memory_order_relaxed);
}
int64_t sc_counter_get(sc_counter *counter) {
    return atomic_load_explicit(&counter->value, memory_order_relaxed);
}
```

- [ ] **Step 3: Write the failing tests**

`Tests/SoundChainCoreTests/AtomicsTests.swift`:
```swift
import CAtomics
import XCTest

final class AtomicsTests: XCTestCase {
    func testPointerStartsNilAndExchangeReturnsPrevious() {
        let cell = sc_atomic_ptr_create()
        defer { sc_atomic_ptr_destroy(cell) }
        XCTAssertNil(sc_atomic_ptr_load(cell))
        let a = UnsafeMutableRawPointer(bitPattern: 0x1000)!
        let b = UnsafeMutableRawPointer(bitPattern: 0x2000)!
        XCTAssertNil(sc_atomic_ptr_exchange(cell, a))
        XCTAssertEqual(sc_atomic_ptr_load(cell), a)
        XCTAssertEqual(sc_atomic_ptr_exchange(cell, b), a)
        XCTAssertEqual(sc_atomic_ptr_exchange(cell, nil), b)
    }

    func testFlagsSetGetAndIgnoreOutOfRange() {
        let flags = sc_flags_create(3)
        defer { sc_flags_destroy(flags) }
        XCTAssertEqual(sc_flags_get(flags, 1), 0)
        sc_flags_set(flags, 1)
        sc_flags_set(flags, 7)
        sc_flags_set(flags, -1)
        XCTAssertEqual(sc_flags_get(flags, 0), 0)
        XCTAssertEqual(sc_flags_get(flags, 1), 1)
        XCTAssertEqual(sc_flags_get(flags, 7), 0)
    }

    func testZeroFlagsIsSafe() {
        let flags = sc_flags_create(0)
        defer { sc_flags_destroy(flags) }
        sc_flags_set(flags, 0)
        XCTAssertEqual(sc_flags_get(flags, 0), 0)
    }

    func testCounterCounts() {
        let counter = sc_counter_create()
        defer { sc_counter_destroy(counter) }
        for _ in 0..<5 { sc_counter_increment(counter) }
        XCTAssertEqual(sc_counter_get(counter), 5)
    }
}
```

`Tests/SoundChainCoreTests/ChainModelTests.swift`:
```swift
import XCTest
@testable import SoundChainCore

final class ChainModelTests: XCTestCase {
    private let delay = ComponentID("aufx", "dely", "appl")!

    private func chain(_ names: String...) -> Chain {
        var chain = Chain()
        for name in names { chain.add(component: delay, name: name, manufacturer: "Apple") }
        return chain
    }
    private func names(_ chain: Chain) -> [String] { chain.slots.map(\.name) }

    func testFourCCRoundTrip() {
        XCTAssertEqual(delay.fourCC, "aufx dely appl")
        XCTAssertEqual(delay.type, 0x6175_6678)
    }

    func testFourCCRejectsWrongLengthOrNonASCII() {
        XCTAssertNil(ComponentID("auf", "dely", "appl"))
        XCTAssertNil(ComponentID("aufx", "délé", "appl"))
    }

    func testNonPrintableBytesShowAsQuestionMarks() {
        let id = ComponentID(type: 0x0061_6263, subtype: delay.subtype, manufacturer: delay.manufacturer)
        XCTAssertEqual(id.fourCC, "?abc dely appl")
    }

    func testAddAppendsAnUnbypassedSlotWithoutState() {
        var c = chain("A")
        let slot = c.add(component: delay, name: "B", manufacturer: "Apple")
        XCTAssertEqual(names(c), ["A", "B"])
        XCTAssertFalse(slot.bypassed)
        XCTAssertNil(slot.state)
        XCTAssertEqual(c.slot(id: slot.id), slot)
    }

    func testRemove() {
        var c = chain("A", "B", "C")
        c.remove(id: c.slots[1].id)
        XCTAssertEqual(names(c), ["A", "C"])
    }

    func testMoveDown() {
        var c = chain("A", "B", "C")
        c.move(from: 0, insertionIndex: 2)
        XCTAssertEqual(names(c), ["B", "A", "C"])
    }

    func testMoveToEnd() {
        var c = chain("A", "B", "C")
        c.move(from: 0, insertionIndex: 3)
        XCTAssertEqual(names(c), ["B", "C", "A"])
    }

    func testMoveUp() {
        var c = chain("A", "B", "C")
        c.move(from: 2, insertionIndex: 0)
        XCTAssertEqual(names(c), ["C", "A", "B"])
    }

    func testMoveOntoItselfIsANoOp() {
        var c = chain("A", "B", "C")
        c.move(from: 1, insertionIndex: 1)
        c.move(from: 1, insertionIndex: 2)
        XCTAssertEqual(names(c), ["A", "B", "C"])
    }

    func testMoveOutOfRangeIsIgnored() {
        var c = chain("A", "B")
        c.move(from: 5, insertionIndex: 0)
        c.move(from: 0, insertionIndex: 9)
        c.move(from: -1, insertionIndex: 0)
        XCTAssertEqual(names(c), ["A", "B"])
    }

    func testSetBypassed() {
        var c = chain("A", "B")
        c.setBypassed(true, id: c.slots[1].id)
        XCTAssertEqual(c.slots.map(\.bypassed), [false, true])
    }

    func testSetStateReportsWhetherItChanged() {
        var c = chain("A")
        let id = c.slots[0].id
        XCTAssertTrue(c.setState(Data([1, 2]), id: id))
        XCTAssertFalse(c.setState(Data([1, 2]), id: id))
        XCTAssertTrue(c.setState(nil, id: id))
        XCTAssertFalse(c.setState(Data([1]), id: UUID()))
    }

    func testCodableRoundTrip() throws {
        var c = chain("A", "B")
        c.masterBypass = true
        c.setBypassed(true, id: c.slots[0].id)
        c.setState(Data([9, 8, 7]), id: c.slots[1].id)
        let decoded = try JSONDecoder().decode(Chain.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
        XCTAssertEqual(decoded.version, Chain.currentVersion)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `cd ~/Code/soundchain-menubar && swift test 2>&1 | tail -20`
Expected: build failure — `cannot find 'ComponentID' in scope` (the atomics tests would pass alone; the model does not exist yet).

- [ ] **Step 5: Implement the model**

`Sources/SoundChainCore/ChainModel.swift`:
```swift
import Foundation

/// An Audio Unit's identity: its type, subtype and manufacturer four-char codes,
/// as `auval` prints them ("aufx dely appl").
public struct ComponentID: Codable, Hashable, Sendable {
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturer: UInt32

    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }

    /// Builds an ID from three four-character ASCII codes; nil if any is not exactly four ASCII characters.
    public init?(_ type: String, _ subtype: String, _ manufacturer: String) {
        guard let t = Self.code(type), let s = Self.code(subtype), let m = Self.code(manufacturer) else { return nil }
        self.init(type: t, subtype: s, manufacturer: m)
    }

    /// "aufx dely appl". Non-printable bytes show as "?".
    public var fourCC: String {
        [type, subtype, manufacturer].map(Self.string).joined(separator: " ")
    }

    static func code(_ text: String) -> UInt32? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" })
    }
}

/// One effect in the chain.
public struct ChainSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var component: ComponentID
    public var name: String
    public var manufacturer: String
    public var bypassed: Bool
    /// The plugin's `fullState`, as a binary property list.
    public var state: Data?

    public init(id: UUID = UUID(), component: ComponentID, name: String, manufacturer: String,
                bypassed: Bool = false, state: Data? = nil) {
        self.id = id
        self.component = component
        self.name = name
        self.manufacturer = manufacturer
        self.bypassed = bypassed
        self.state = state
    }
}

/// The one global effect chain, in processing order.
public struct Chain: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var masterBypass: Bool
    public var slots: [ChainSlot]

    public init(masterBypass: Bool = false, slots: [ChainSlot] = []) {
        version = Chain.currentVersion
        self.masterBypass = masterBypass
        self.slots = slots
    }

    public func slot(id: UUID) -> ChainSlot? { slots.first { $0.id == id } }

    @discardableResult
    public mutating func add(component: ComponentID, name: String, manufacturer: String) -> ChainSlot {
        let slot = ChainSlot(component: component, name: name, manufacturer: manufacturer)
        slots.append(slot)
        return slot
    }

    public mutating func remove(id: UUID) { slots.removeAll { $0.id == id } }

    /// Moves the slot at `from` so it lands before the slot that was at
    /// `insertionIndex` (the index NSTableView reports for a drop "above" a row).
    /// Out-of-range input is ignored.
    public mutating func move(from: Int, insertionIndex: Int) {
        guard slots.indices.contains(from), (0...slots.count).contains(insertionIndex) else { return }
        let slot = slots.remove(at: from)
        let target = insertionIndex > from ? insertionIndex - 1 : insertionIndex
        slots.insert(slot, at: target)
    }

    public mutating func setBypassed(_ bypassed: Bool, id: UUID) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i].bypassed = bypassed
    }

    /// Stores a plugin's state. Returns true only when the stored value changed.
    @discardableResult
    public mutating func setState(_ state: Data?, id: UUID) -> Bool {
        guard let i = slots.firstIndex(where: { $0.id == id }), slots[i].state != state else { return false }
        slots[i].state = state
        return true
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed 17 tests, with 0 failures` (4 atomics + 13 model). Also `swift build` succeeds (placeholder executable).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Scaffold package with C atomics and chain model

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Chain persistence

**Files:**
- Create: `Sources/SoundChainCore/ChainStore.swift`
- Test: `Tests/SoundChainCoreTests/ChainStoreTests.swift`

**Interfaces:**
- Consumes: `Chain`, `ChainSlot`, `ComponentID` (Task 1).
- Produces: `struct ChainLoad: Equatable { var chain: Chain; var corruptBackup: URL? }`;
  `struct ChainStore { let url: URL; init(url:); static func defaultURL() -> URL; func load(now: Date = Date()) -> ChainLoad; func save(_ chain: Chain) throws }`.

- [ ] **Step 1: Write the failing tests**

`Tests/SoundChainCoreTests/ChainStoreTests.swift`:
```swift
import XCTest
@testable import SoundChainCore

final class ChainStoreTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("chain.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChainStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sampleChain() -> Chain {
        var chain = Chain(masterBypass: true)
        let a = chain.add(component: ComponentID("aufx", "dely", "appl")!, name: "AUDelay", manufacturer: "Apple")
        chain.add(component: ComponentID("aufx", "nbeq", "appl")!, name: "AUNBandEQ", manufacturer: "Apple")
        chain.setBypassed(true, id: a.id)
        chain.setState(Data([0, 1, 2, 255]), id: a.id)
        return chain
    }

    func testDefaultURLIsInApplicationSupport() {
        XCTAssertTrue(ChainStore.defaultURL().path.hasSuffix("Library/Application Support/SoundChain/chain.json"))
    }

    func testMissingFileGivesAnEmptyChain() {
        let load = ChainStore(url: url).load()
        XCTAssertEqual(load.chain, Chain())
        XCTAssertNil(load.corruptBackup)
    }

    func testRoundTrip() throws {
        let store = ChainStore(url: url)
        try store.save(sampleChain())
        let load = store.load()
        XCTAssertEqual(load.chain, sampleChain().withSameIDs(as: load.chain))
        XCTAssertNil(load.corruptBackup)
    }

    func testSaveCreatesMissingDirectories() throws {
        let nested = dir.appendingPathComponent("a/b/chain.json")
        try ChainStore(url: nested).save(Chain())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testCorruptFileIsBackedUpAndAnEmptyChainUsed() throws {
        try Data("not json".utf8).write(to: url)
        let load = ChainStore(url: url).load(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(load.chain, Chain())
        let backup = try XCTUnwrap(load.corruptBackup)
        XCTAssertEqual(backup.lastPathComponent, "chain.json.corrupt-19700101-000000")
        XCTAssertEqual(try Data(contentsOf: backup), Data("not json".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileFromAFutureVersionIsTreatedAsCorrupt() throws {
        try Data(#"{"version":99,"masterBypass":false,"slots":[]}"#.utf8).write(to: url)
        let load = ChainStore(url: url).load()
        XCTAssertEqual(load.chain, Chain())
        XCTAssertNotNil(load.corruptBackup)
    }
}

private extension Chain {
    /// `sampleChain()` makes fresh UUIDs each call; copy the IDs across so equality compares content.
    func withSameIDs(as other: Chain) -> Chain {
        var copy = self
        for i in copy.slots.indices where other.slots.indices.contains(i) { copy.slots[i].id = other.slots[i].id }
        return copy
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChainStoreTests 2>&1 | tail -5`
Expected: build failure — `cannot find 'ChainStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/SoundChainCore/ChainStore.swift`:
```swift
import Foundation

public struct ChainLoad: Equatable {
    public var chain: Chain
    /// Where an unreadable chain file was moved, when that happened.
    public var corruptBackup: URL?

    public init(chain: Chain, corruptBackup: URL?) {
        self.chain = chain
        self.corruptBackup = corruptBackup
    }
}

/// Reads and writes the chain as JSON. Writes are atomic (temp file, then rename).
public struct ChainStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SoundChain", isDirectory: true).appendingPathComponent("chain.json")
    }

    /// A missing file gives an empty chain. An unreadable one, or one written by a
    /// newer version, is moved aside to `chain.json.corrupt-<UTC timestamp>` and an
    /// empty chain is returned, so nothing is lost and the app still starts.
    public func load(now: Date = Date()) -> ChainLoad {
        guard let data = try? Data(contentsOf: url) else { return ChainLoad(chain: Chain(), corruptBackup: nil) }
        if let chain = try? JSONDecoder().decode(Chain.self, from: data), chain.version <= Chain.currentVersion {
            return ChainLoad(chain: chain, corruptBackup: nil)
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(Self.stamp(now))")
        try? FileManager.default.moveItem(at: url, to: backup)
        return ChainLoad(chain: Chain(), corruptBackup: backup)
    }

    public func save(_ chain: Chain) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(chain).write(to: url, options: .atomic)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 23 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add chain persistence with corrupt-file recovery

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Plugin catalog grouping and search

**Files:**
- Create: `Sources/SoundChainCore/PluginCatalog.swift`
- Test: `Tests/SoundChainCoreTests/PluginCatalogTests.swift`

**Interfaces:**
- Consumes: `ComponentID` (Task 1).
- Produces: `struct CatalogEntry: Hashable, Sendable { var component: ComponentID; var name: String; var manufacturer: String; var loadError: String?; init(component:name:manufacturer:loadError: String? = nil) }`;
  `struct CatalogGroup: Equatable, Sendable { var manufacturer: String; var entries: [CatalogEntry] }`;
  `enum PluginCatalog { static func groups(_ entries: [CatalogEntry], search: String = "") -> [CatalogGroup] }`.

- [ ] **Step 1: Write the failing tests**

`Tests/SoundChainCoreTests/PluginCatalogTests.swift`:
```swift
import XCTest
@testable import SoundChainCore

final class PluginCatalogTests: XCTestCase {
    private func entry(_ name: String, _ maker: String, _ sub: String, error: String? = nil) -> CatalogEntry {
        CatalogEntry(component: ComponentID("aufx", sub, "test")!, name: name, manufacturer: maker, loadError: error)
    }

    private lazy var all: [CatalogEntry] = [
        entry("Vinyl", "iZotope", "vnyl"),
        entry("Ozone 9 Elements", "iZotope", "ozn9"),
        entry("Raum", "Native Instruments", "raum"),
        entry("AUNBandEQ", "Apple", "nbeq"),
        entry("AUDelay", "Apple", "dely"),
        entry("H-Comp (s)", "Waves", "hcmp", error: "Couldn't open: -10875"),
    ]

    private func shape(_ groups: [CatalogGroup]) -> [String] {
        groups.map { "\($0.manufacturer): \($0.entries.map(\.name).joined(separator: ", "))" }
    }

    func testEmptySearchGroupsEverythingSortedCaseInsensitively() {
        XCTAssertEqual(shape(PluginCatalog.groups(all)), [
            "Apple: AUDelay, AUNBandEQ",
            "iZotope: Ozone 9 Elements, Vinyl",
            "Native Instruments: Raum",
            "Waves: H-Comp (s)",
        ])
    }

    func testWhitespaceOnlySearchIsTheSameAsEmpty() {
        XCTAssertEqual(PluginCatalog.groups(all, search: "   "), PluginCatalog.groups(all))
    }

    func testSearchMatchesNameCaseInsensitively() {
        XCTAssertEqual(shape(PluginCatalog.groups(all, search: "OZONE")), ["iZotope: Ozone 9 Elements"])
    }

    func testSearchMatchesManufacturer() {
        XCTAssertEqual(shape(PluginCatalog.groups(all, search: "izotope")), ["iZotope: Ozone 9 Elements, Vinyl"])
    }

    func testEveryTermMustMatch() {
        XCTAssertEqual(shape(PluginCatalog.groups(all, search: "izotope vinyl")), ["iZotope: Vinyl"])
        XCTAssertEqual(PluginCatalog.groups(all, search: "izotope raum"), [])
    }

    func testUnloadableEntriesAreKeptAndStillFlagged() {
        let groups = PluginCatalog.groups(all, search: "waves")
        XCTAssertEqual(groups.first?.entries.first?.loadError, "Couldn't open: -10875")
    }

    func testDuplicateComponentsAreCollapsed() {
        let doubled = all + [entry("Vinyl", "iZotope", "vnyl")]
        XCTAssertEqual(PluginCatalog.groups(doubled), PluginCatalog.groups(all))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PluginCatalogTests 2>&1 | tail -5`
Expected: build failure — `cannot find 'CatalogEntry' in scope`.

- [ ] **Step 3: Implement**

`Sources/SoundChainCore/PluginCatalog.swift`:
```swift
import Foundation

/// An installed effect as the Add picker shows it.
public struct CatalogEntry: Hashable, Sendable {
    public var component: ComponentID
    public var name: String
    public var manufacturer: String
    /// Why this plugin failed to load earlier in this session; nil if it has not failed.
    public var loadError: String?

    public init(component: ComponentID, name: String, manufacturer: String, loadError: String? = nil) {
        self.component = component
        self.name = name
        self.manufacturer = manufacturer
        self.loadError = loadError
    }
}

public struct CatalogGroup: Equatable, Sendable {
    public var manufacturer: String
    public var entries: [CatalogEntry]
}

public enum PluginCatalog {
    /// Groups entries by manufacturer (groups and names sorted case-insensitively),
    /// keeping only those where every whitespace-separated search term appears in
    /// the name or manufacturer. Unloadable entries stay in, flagged by `loadError`.
    /// Entries with the same component are collapsed to the first.
    public static func groups(_ entries: [CatalogEntry], search: String = "") -> [CatalogGroup] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<ComponentID>()
        let matching = entries.filter { entry in
            guard seen.insert(entry.component).inserted else { return false }
            return terms.allSatisfy { term in
                entry.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || entry.manufacturer.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        let byMaker = Dictionary(grouping: matching, by: \.manufacturer)
        return byMaker.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { maker in
                CatalogGroup(manufacturer: maker, entries: byMaker[maker]!.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                })
            }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add plugin catalog grouping and search

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Crash guard

**Files:**
- Create: `Sources/SoundChainCore/CrashGuard.swift`
- Test: `Tests/SoundChainCoreTests/CrashGuardTests.swift`

**Interfaces:**
- Produces: `protocol FlagStore: AnyObject { func bool(forKey:) -> Bool; func integer(forKey:) -> Int; func set(_ value: Any?, forKey: String) }` (UserDefaults conforms);
  `final class CrashGuard { static let threshold = 2; init(store: FlagStore); var uncleanExits: Int; func recordLaunch() -> Bool; func markStable(); func recordCleanExit() }`.

- [ ] **Step 1: Write the failing tests**

`Tests/SoundChainCoreTests/CrashGuardTests.swift`:
```swift
import XCTest
@testable import SoundChainCore

private final class MemoryStore: FlagStore {
    var values: [String: Any] = [:]
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class CrashGuardTests: XCTestCase {
    private var store: MemoryStore!
    private var guardian: CrashGuard { CrashGuard(store: store) }   // a fresh instance per "launch"

    override func setUp() { store = MemoryStore() }

    func testFirstLaunchDoesNotBypass() {
        XCTAssertFalse(guardian.recordLaunch())
    }

    func testOneCrashDoesNotBypass() {
        _ = guardian.recordLaunch()          // then crash: no clean exit
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 1)
    }

    func testTwoCrashesInARowBypass() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()
        XCTAssertTrue(guardian.recordLaunch())
    }

    func testCleanExitResetsTheCount() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()
        guardian.recordCleanExit()
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 0)
    }

    func testStableRunResetsTheCountSoALaterCrashStartsFresh() {
        _ = guardian.recordLaunch()
        _ = guardian.recordLaunch()          // 1 unclean
        guardian.markStable()                // ran 60 s fine, then crashed
        XCTAssertFalse(guardian.recordLaunch())
        XCTAssertEqual(guardian.uncleanExits, 1)
    }

    func testUserDefaultsConforms() {
        let suite = "CrashGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = CrashGuard(store: defaults).recordLaunch()
        _ = CrashGuard(store: defaults).recordLaunch()
        XCTAssertTrue(CrashGuard(store: defaults).recordLaunch())
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CrashGuardTests 2>&1 | tail -5`
Expected: build failure — `cannot find type 'FlagStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/SoundChainCore/CrashGuard.swift`:
```swift
import Foundation

public protocol FlagStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: FlagStore {}

/// Detects a crash loop. A "running" marker is set at launch and cleared on a clean
/// quit; finding it still set at the next launch means the last run ended uncleanly.
/// After `threshold` unclean exits in a row the app starts with master bypass on, so
/// a plugin that crashes the app cannot keep crashing it.
public final class CrashGuard {
    public static let threshold = 2
    static let runningKey = "CrashGuardRunning"
    static let uncleanKey = "CrashGuardUncleanExits"

    private let store: FlagStore

    public init(store: FlagStore) { self.store = store }

    public var uncleanExits: Int { store.integer(forKey: Self.uncleanKey) }

    /// Call once, first thing at launch. Returns true when the app must start bypassed.
    public func recordLaunch() -> Bool {
        if store.bool(forKey: Self.runningKey) {
            store.set(uncleanExits + 1, forKey: Self.uncleanKey)
        }
        store.set(true, forKey: Self.runningKey)
        return uncleanExits >= Self.threshold
    }

    /// Call once the app has run long enough to count as stable (60 s).
    public func markStable() { store.set(0, forKey: Self.uncleanKey) }

    public func recordCleanExit() {
        store.set(false, forKey: Self.runningKey)
        store.set(0, forKey: Self.uncleanKey)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add crash-loop guard

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Real-time buffer helpers (tap input, channel map, sample guard)

**Files:**
- Create: `Sources/SoundChainCore/TapInput.swift`, `Sources/SoundChainCore/ChannelMap.swift`, `Sources/SoundChainCore/SampleGuard.swift`
- Test: `Tests/SoundChainCoreTests/TestBuffers.swift`, `TapInputTests.swift`, `ChannelMapTests.swift`, `SampleGuardTests.swift`

**Interfaces:**
- Produces:
  `enum TapInput { static func read(_ input: UnsafeMutableAudioBufferListPointer, interleaved: Bool, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, capacity: Int) -> Int }` — returns frames copied, 0 on any mismatch;
  `enum ChannelMap { static func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, to output: UnsafeMutableAudioBufferListPointer); static func zero(_ output: UnsafeMutableAudioBufferListPointer) }`;
  `enum SampleGuard { @discardableResult static func sanitize(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool }`.

Background for the implementer: the aggregate device's IO proc gets one input `AudioBufferList` holding the output device's own input streams (if it has any, e.g. the Scarlett's inputs) **followed by** the tap's stream. The tap is stereo 32-bit float: either one interleaved buffer with 2 channels, or two 1-channel buffers. So the tap is always at the end of the list. The output list is the output device's streams, in any layout (one interleaved N-channel buffer, or several).

- [ ] **Step 1: Write the test helper and failing tests**

`Tests/SoundChainCoreTests/TestBuffers.swift`:
```swift
import CoreAudio
import Foundation

/// Owns an AudioBufferList whose buffers have the given channel counts, each `frames` long, zero-filled.
final class TestABL {
    let list: UnsafeMutableAudioBufferListPointer

    init(frames: Int, layout: [Int]) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (i, channels) in layout.enumerated() {
            let bytes = frames * channels * MemoryLayout<Float>.size
            let data = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: max(bytes, 1))
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes), mData: data)
        }
    }

    func samples(_ buffer: Int) -> UnsafeMutablePointer<Float> {
        list[buffer].mData!.assumingMemoryBound(to: Float.self)
    }

    func array(_ buffer: Int) -> [Float] {
        let count = Int(list[buffer].mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: samples(buffer), count: count))
    }

    func fill(_ buffer: Int, _ values: [Float]) {
        for (i, v) in values.enumerated() { samples(buffer)[i] = v }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

/// A heap float array for the left/right destinations.
final class Floats {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    init(_ values: [Float]) {
        count = values.count
        pointer = .allocate(capacity: max(count, 1))
        pointer.initialize(from: values, count: count)
    }
    convenience init(zeros count: Int) { self.init([Float](repeating: 0, count: count)) }
    var array: [Float] { Array(UnsafeBufferPointer(start: pointer, count: count)) }
    deinit { pointer.deallocate() }
}
```

`Tests/SoundChainCoreTests/TapInputTests.swift`:
```swift
import CoreAudio
import XCTest
@testable import SoundChainCore

final class TapInputTests: XCTestCase {
    func testInterleavedTapIsTheLastBufferAfterDeviceInputs() {
        let abl = TestABL(frames: 4, layout: [1, 2])      // device mic, then tap
        abl.fill(0, [9, 9, 9, 9])
        abl.fill(1, [1, -1, 2, -2, 3, -3, 4, -4])
        let l = Floats(zeros: 8), r = Floats(zeros: 8)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 8), 4)
        XCTAssertEqual(Array(l.array.prefix(4)), [1, 2, 3, 4])
        XCTAssertEqual(Array(r.array.prefix(4)), [-1, -2, -3, -4])
    }

    func testNonInterleavedTapIsTheLastTwoBuffers() {
        let abl = TestABL(frames: 3, layout: [2, 1, 1])   // device stereo input, then tap L, tap R
        abl.fill(1, [1, 2, 3])
        abl.fill(2, [4, 5, 6])
        let l = Floats(zeros: 3), r = Floats(zeros: 3)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 3), 3)
        XCTAssertEqual(l.array, [1, 2, 3])
        XCTAssertEqual(r.array, [4, 5, 6])
    }

    func testMonoInterleavedTapIsDuplicated() {
        let abl = TestABL(frames: 2, layout: [1])
        abl.fill(0, [0.5, 0.25])
        let l = Floats(zeros: 2), r = Floats(zeros: 2)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 2), 2)
        XCTAssertEqual(l.array, [0.5, 0.25])
        XCTAssertEqual(r.array, [0.5, 0.25])
    }

    func testMoreFramesThanCapacityReadsNothing() {
        let abl = TestABL(frames: 8, layout: [2])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
        let split = TestABL(frames: 8, layout: [1, 1])   // keep it alive across the call
        XCTAssertEqual(TapInput.read(split.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testEmptyListReadsNothing() {
        let abl = TestABL(frames: 4, layout: [])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testNilDataReadsNothing() {
        let abl = TestABL(frames: 4, layout: [2])
        let saved = abl.list[0].mData
        abl.list[0].mData = nil
        defer { abl.list[0].mData = saved }
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: true, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }

    func testNonInterleavedWithMismatchedChannelCountsReadsNothing() {
        let abl = TestABL(frames: 4, layout: [2, 2])
        let l = Floats(zeros: 4), r = Floats(zeros: 4)
        XCTAssertEqual(TapInput.read(abl.list, interleaved: false, left: l.pointer, right: r.pointer, capacity: 4), 0)
    }
}
```

`Tests/SoundChainCoreTests/ChannelMapTests.swift`:
```swift
import CoreAudio
import XCTest
@testable import SoundChainCore

final class ChannelMapTests: XCTestCase {
    private let left = Floats([1, 2, 3, 4])
    private let right = Floats([-1, -2, -3, -4])

    func testInterleavedStereo() {
        let out = TestABL(frames: 4, layout: [2])
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 4, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 2, -2, 3, -3, 4, -4])
    }

    func testSixChannelInterleavedZeroesTheExtraChannels() {
        let out = TestABL(frames: 2, layout: [6])
        out.fill(0, [Float](repeating: 9, count: 12))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 0, 0, 0, 0, 2, -2, 0, 0, 0, 0])
    }

    func testNonInterleavedStereo() {
        let out = TestABL(frames: 4, layout: [1, 1])
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 4, to: out.list)
        XCTAssertEqual(out.array(0), [1, 2, 3, 4])
        XCTAssertEqual(out.array(1), [-1, -2, -3, -4])
    }

    func testChannelsSpanBuffers() {
        let out = TestABL(frames: 2, layout: [1, 3])        // L alone, then R + 2 extras
        out.fill(1, [Float](repeating: 9, count: 6))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, 2])
        XCTAssertEqual(out.array(1), [-1, 0, 0, -2, 0, 0])
    }

    func testMonoDeviceGetsTheAverage() {
        let l = Floats([1, 0.5]), r = Floats([0, 0.5])
        let out = TestABL(frames: 2, layout: [1])
        ChannelMap.write(left: l.pointer, right: r.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [0.5, 0.5])
    }

    func testShortRenderZeroesTheRestOfTheBuffer() {
        let out = TestABL(frames: 4, layout: [2])
        out.fill(0, [Float](repeating: 9, count: 8))
        ChannelMap.write(left: left.pointer, right: right.pointer, frames: 2, to: out.list)
        XCTAssertEqual(out.array(0), [1, -1, 2, -2, 0, 0, 0, 0])
    }

    func testZero() {
        let out = TestABL(frames: 2, layout: [2, 1])
        out.fill(0, [1, 1, 1, 1]); out.fill(1, [1, 1])
        ChannelMap.zero(out.list)
        XCTAssertEqual(out.array(0), [0, 0, 0, 0])
        XCTAssertEqual(out.array(1), [0, 0])
    }
}
```

`Tests/SoundChainCoreTests/SampleGuardTests.swift`:
```swift
import XCTest
@testable import SoundChainCore

final class SampleGuardTests: XCTestCase {
    func testFiniteSamplesAreLeftAlone() {
        let l = Floats([0.1, -0.2]), r = Floats([0.3, 1.5])
        XCTAssertFalse(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array, [0.1, -0.2])
        XCTAssertEqual(r.array, [0.3, 1.5])
    }

    func testNaNZeroesBothChannels() {
        let l = Floats([0.1, 0.2]), r = Floats([.nan, 0.3])
        XCTAssertTrue(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array, [0, 0])
        XCTAssertEqual(r.array, [0, 0])
    }

    func testInfinityZeroesBothChannels() {
        let l = Floats([0.1, -.infinity]), r = Floats([0.2, 0.3])
        XCTAssertTrue(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 2))
        XCTAssertEqual(l.array + r.array, [0, 0, 0, 0])
    }

    func testOnlyTheRenderedFramesAreChecked() {
        let l = Floats([0.1, .nan]), r = Floats([0.2, 0.3])
        XCTAssertFalse(SampleGuard.sanitize(left: l.pointer, right: r.pointer, frames: 1))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build failure — `cannot find 'TapInput' in scope` (and `ChannelMap`, `SampleGuard`).

- [ ] **Step 3: Implement**

`Sources/SoundChainCore/TapInput.swift`:
```swift
import CoreAudio

/// Pulls the tap's stereo stream out of the aggregate device's input list.
/// Audio-thread safe: no allocation, no locks.
public enum TapInput {
    /// The tap's stream is always last: one interleaved buffer (2 channels, or 1 for a
    /// mono tap, which is duplicated), or two 1-channel buffers when non-interleaved.
    /// Returns the frames copied, or 0 when the list has no tap stream of that shape,
    /// a buffer has no data, or the block is larger than `capacity`.
    public static func read(_ input: UnsafeMutableAudioBufferListPointer, interleaved: Bool,
                            left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                            capacity: Int) -> Int {
        let count = input.count
        guard count > 0 else { return 0 }
        let floatSize = MemoryLayout<Float>.size

        if interleaved {
            let buffer = input[count - 1]
            let channels = Int(buffer.mNumberChannels)
            guard channels >= 1, let data = buffer.mData else { return 0 }
            let frames = Int(buffer.mDataByteSize) / (floatSize * channels)
            guard frames <= capacity else { return 0 }
            let source = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let base = frame * channels
                left[frame] = source[base]
                right[frame] = channels > 1 ? source[base + 1] : source[base]
            }
            return frames
        }

        let leftBuffer = count >= 2 ? input[count - 2] : input[count - 1]
        let rightBuffer = input[count - 1]
        guard leftBuffer.mNumberChannels == 1, rightBuffer.mNumberChannels == 1,
              let leftData = leftBuffer.mData, let rightData = rightBuffer.mData else { return 0 }
        let frames = Int(rightBuffer.mDataByteSize) / floatSize
        guard frames <= capacity, Int(leftBuffer.mDataByteSize) / floatSize == frames else { return 0 }
        left.update(from: leftData.assumingMemoryBound(to: Float.self), count: frames)
        right.update(from: rightData.assumingMemoryBound(to: Float.self), count: frames)
        return frames
    }
}
```

`Sources/SoundChainCore/ChannelMap.swift`:
```swift
import CoreAudio
import Foundation

/// Writes the processed stereo signal into whatever stream layout the output device has.
/// Audio-thread safe: no allocation, no locks.
public enum ChannelMap {
    /// Channel 1 gets left and channel 2 gets right, counting channels across buffers
    /// in order; every other channel is zeroed. A device with a single channel gets
    /// (L+R)/2. Frames beyond `frames` in each buffer are zeroed.
    public static func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int,
                             to output: UnsafeMutableAudioBufferListPointer) {
        var totalChannels = 0
        for b in 0..<output.count { totalChannels += Int(output[b].mNumberChannels) }

        var firstChannel = 0
        for b in 0..<output.count {
            let buffer = output[b]
            let channels = Int(buffer.mNumberChannels)
            if channels > 0, let data = buffer.mData {
                let destination = data.assumingMemoryBound(to: Float.self)
                let capacity = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let rendered = min(frames, capacity)
                for c in 0..<channels {
                    let channel = firstChannel + c
                    for frame in 0..<capacity {
                        let value: Float
                        if frame >= rendered {
                            value = 0
                        } else if totalChannels == 1 {
                            value = (left[frame] + right[frame]) * 0.5
                        } else if channel == 0 {
                            value = left[frame]
                        } else if channel == 1 {
                            value = right[frame]
                        } else {
                            value = 0
                        }
                        destination[frame * channels + c] = value
                    }
                }
            }
            firstChannel += channels
        }
    }

    public static func zero(_ output: UnsafeMutableAudioBufferListPointer) {
        for b in 0..<output.count {
            if let data = output[b].mData { memset(data, 0, Int(output[b].mDataByteSize)) }
        }
    }
}
```

`Sources/SoundChainCore/SampleGuard.swift`:
```swift
/// Protects speakers and ears from a misbehaving plugin. Audio-thread safe.
public enum SampleGuard {
    /// If any of the first `frames` samples in either channel is NaN or infinite,
    /// zeroes both channels and returns true.
    @discardableResult
    public static func sanitize(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                                frames: Int) -> Bool {
        for frame in 0..<frames where !left[frame].isFinite || !right[frame].isFinite {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return true
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add real-time tap input, channel map and sample guard

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Plugin host, render chain, and `--selftest`

**Files:**
- Create: `Sources/SoundChain/PluginHost.swift`, `Sources/SoundChain/RenderChain.swift`, `Sources/SoundChain/SelfTest.swift`
- Modify: `Sources/SoundChain/main.swift` (replace placeholder)

**Interfaces:**
- Consumes: `ComponentID` (Task 1); `sc_flags_*` (Task 1).
- Produces:
  `extension ComponentID { init(_ d: AudioComponentDescription); var audioComponentDescription: AudioComponentDescription }`;
  `struct RenderFormat: Equatable { var sampleRate: Double; var maxFrames: Int; var avFormat: AVAudioFormat }`;
  `enum PluginError: LocalizedError { notInstalled(ComponentID), instantiate(String), noAudioBusses, badState }`;
  `final class LoadedPlugin { let unit: AUAudioUnit; private(set) var preparedFormat: RenderFormat?; static func load(_ id: ComponentID, completion: @escaping (Result<LoadedPlugin, Error>) -> Void) /* completes on main */; func prepare(_ format: RenderFormat) throws; func captureState() -> Data?; func restoreState(_ data: Data) throws }`;
  `final class RenderChain { init(stages: [(slotID: UUID, unit: AUAudioUnit)], maxFrames: Int); let maxFrames: Int; let slotIDs: [UUID]; let inputLeft, inputRight: UnsafeMutablePointer<Float>; var stageCount: Int; func process(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>) -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>); func failedSlotIDs() -> [UUID] }`;
  `enum SelfTest { static func run() -> Bool; static let sampleRate: Double; static let blockFrames: Int; static let delay, eq: ComponentID; static func loadSync(_:timeout:) throws -> LoadedPlugin; static func spin(timeout:until:) -> Bool; static func render(_:blocks:) -> ([Float], [Float]); static func sine(block:) -> [Float] }`.

This task has no unit tests; the test is `SoundChain --selftest`, which drives real Apple AUs offline. Write the self-test first, watch it fail to build, then implement.

- [ ] **Step 1: Write the self-test and the entry point**

`Sources/SoundChain/SelfTest.swift`:
```swift
import AudioToolbox
import Foundation
import SoundChainCore

/// `SoundChain --selftest`: renders a sine through real Apple AUs offline and checks
/// the chain behaves. No tap and no permission needed. Exits non-zero on failure.
enum SelfTest {
    static let sampleRate = 48_000.0
    static let blockFrames = 512
    static let delay = ComponentID("aufx", "dely", "appl")!   // AUDelay
    static let eq = ComponentID("aufx", "nbeq", "appl")!      // AUNBandEQ

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "PASS  \(what)" : "FAIL  \(what)")
            if !ok { failures.append(what) }
        }

        do {
            try renderChecks(check)
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }

        print(failures.isEmpty ? "\nAll self-tests passed." : "\n\(failures.count) self-test(s) failed.")
        return failures.isEmpty
    }

    static func renderChecks(_ check: (Bool, String) -> Void) throws {
        let format = RenderFormat(sampleRate: sampleRate, maxFrames: 4096)
        let delayPlugin = try loadSync(delay)
        try delayPlugin.prepare(format)
        let eqPlugin = try loadSync(eq)
        try eqPlugin.prepare(format)

        let empty = RenderChain(stages: [], maxFrames: format.maxFrames)
        let (el, er) = render(empty, blocks: 4)
        check(el == sine(block: 3) && er == sine(block: 3), "empty chain passes input through bit-exactly")

        func exercise(_ label: String, _ units: [AUAudioUnit]) {
            let chain = RenderChain(stages: units.map { (slotID: UUID(), unit: $0) }, maxFrames: format.maxFrames)
            let (l, r) = render(chain, blocks: 4)
            check(l != sine(block: 3), "\(label): output differs from input")
            check((l + r).allSatisfy(\.isFinite), "\(label): output is finite")
            check(chain.failedSlotIDs().isEmpty, "\(label): no render errors")
        }
        exercise("one stage", [delayPlugin.unit])
        exercise("two stages", [delayPlugin.unit, eqPlugin.unit])

        let full = RenderChain(stages: [(slotID: UUID(), unit: delayPlugin.unit)], maxFrames: format.maxFrames)
        let (fl, _) = render(full, blocks: 1, frames: format.maxFrames)
        check(fl.count == format.maxFrames && fl.allSatisfy(\.isFinite), "renders a full maxFrames block")

        // State capture and restore, through AUDelay's wet/dry mix (parameter address 0).
        guard let mix = delayPlugin.unit.parameterTree?.parameter(withAddress: 0) else {
            check(false, "AUDelay exposes wet/dry mix at address 0")
            return
        }
        let before = mix.value
        let original = delayPlugin.captureState()
        check(original != nil, "state can be captured")
        mix.value = before == 100 ? 0 : 100
        check(delayPlugin.captureState() != original, "captured state reflects a parameter change")
        if let original { try delayPlugin.restoreState(original) }
        check(abs(mix.value - before) < 0.001, "restoring state brings the parameter back")
        check((try? delayPlugin.restoreState(Data("not a plist".utf8))) == nil, "unreadable state is rejected")
    }

    // MARK: Helpers (also used by later self-tests)

    /// Loads a plugin, spinning the main run loop until `LoadedPlugin.load` completes.
    static func loadSync(_ id: ComponentID, timeout: TimeInterval = 10) throws -> LoadedPlugin {
        var result: Result<LoadedPlugin, Error>?
        LoadedPlugin.load(id) { result = $0 }
        _ = spin(timeout: timeout) { result != nil }
        guard let result else { throw PluginError.instantiate("timed out loading \(id.fourCC)") }
        return try result.get()
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes. Returns whether it held.
    @discardableResult
    static func spin(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Feeds `blocks` consecutive sine blocks through `chain`; returns the last block's output.
    static func render(_ chain: RenderChain, blocks: Int, frames: Int = blockFrames) -> ([Float], [Float]) {
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = .sampleTimeValid
        var result: ([Float], [Float]) = ([], [])
        for block in 0..<blocks {
            let input = sine(block: block, frames: frames)
            chain.inputLeft.update(from: input, count: frames)
            chain.inputRight.update(from: input, count: frames)
            timestamp.mSampleTime = Double(block * frames)
            let out = withUnsafePointer(to: timestamp) { chain.process(frames: frames, timestamp: $0) }
            result = (Array(UnsafeBufferPointer(start: out.left, count: frames)),
                      Array(UnsafeBufferPointer(start: out.right, count: frames)))
        }
        return result
    }

    /// Block `block` of a continuous 1 kHz sine at half scale.
    static func sine(block: Int, frames: Int = blockFrames) -> [Float] {
        (0..<frames).map { i in
            Float(0.5 * sin(2 * Double.pi * 1000 * Double(block * frames + i) / sampleRate))
        }
    }
}
```

`Sources/SoundChain/main.swift`:
```swift
import Foundation
import StatusItemKit

LoginCLI.runIfRequested()

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
print("SoundChain: the menu-bar app arrives in Task 9. Try --selftest.")
```

- [ ] **Step 2: Build to verify it fails**

Run: `swift build 2>&1 | grep error: | head -5`
Expected: errors such as `cannot find 'RenderFormat' in scope` and `cannot find 'LoadedPlugin' in scope`.

- [ ] **Step 3: Implement the plugin host**

`Sources/SoundChain/PluginHost.swift`:
```swift
import AVFoundation
import AudioToolbox
import Foundation
import SoundChainCore

extension ComponentID {
    init(_ description: AudioComponentDescription) {
        self.init(type: description.componentType, subtype: description.componentSubType,
                  manufacturer: description.componentManufacturer)
    }

    var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
}

/// The format every plugin in the chain runs at: stereo, 32-bit float, non-interleaved.
struct RenderFormat: Equatable {
    var sampleRate: Double
    var maxFrames: Int

    var avFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)! }
}

enum PluginError: LocalizedError {
    case notInstalled(ComponentID)
    case instantiate(String)
    case noAudioBusses
    case badState

    var errorDescription: String? {
        switch self {
        case .notInstalled(let id): return "Not installed (\(id.fourCC))"
        case .instantiate(let why): return "Couldn't open: \(why)"
        case .noAudioBusses: return "Has no audio input or output"
        case .badState: return "Saved settings are unreadable"
        }
    }
}

/// One instantiated Audio Unit. Main thread only.
final class LoadedPlugin {
    let unit: AUAudioUnit
    private(set) var preparedFormat: RenderFormat?

    init(unit: AUAudioUnit) { self.unit = unit }

    /// Instantiates a plugin (AUv2 in-process; AUv3 per the system default).
    /// `completion` always runs on the main queue.
    static func load(_ id: ComponentID, completion: @escaping (Result<LoadedPlugin, Error>) -> Void) {
        var description = id.audioComponentDescription
        guard AudioComponentFindNext(nil, &description) != nil else {
            DispatchQueue.main.async { completion(.failure(PluginError.notInstalled(id))) }
            return
        }
        AUAudioUnit.instantiate(with: description, options: []) { unit, error in
            DispatchQueue.main.async {
                if let unit {
                    completion(.success(LoadedPlugin(unit: unit)))
                } else {
                    let ns = error.map { $0 as NSError }
                    let why = ns.map { "\($0.localizedDescription) (\($0.code))" } ?? "unknown error"
                    completion(.failure(PluginError.instantiate(why)))
                }
            }
        }
    }

    /// (Re)allocates render resources for `format`. Only call while this plugin's
    /// unit is not in a published RenderChain (see ChainRunner.setFormat).
    func prepare(_ format: RenderFormat) throws {
        if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        guard unit.inputBusses.count > 0, unit.outputBusses.count > 0 else { throw PluginError.noAudioBusses }
        try unit.inputBusses[0].setFormat(format.avFormat)
        try unit.outputBusses[0].setFormat(format.avFormat)
        unit.maximumFramesToRender = AUAudioFrameCount(format.maxFrames)
        try unit.allocateRenderResources()
        preparedFormat = format
    }

    /// The plugin's `fullState` as a binary property list.
    func captureState() -> Data? {
        guard let state = unit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    func restoreState(_ data: Data) throws {
        guard let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else {
            throw PluginError.badState
        }
        unit.fullState = state
    }
}
```

- [ ] **Step 4: Implement the render chain**

`Sources/SoundChain/RenderChain.swift`:
```swift
import AudioToolbox
import CAtomics
import Foundation

/// An immutable snapshot of the chain as the audio thread runs it: the enabled
/// plugins in order, with every buffer allocated up front. The main thread builds a
/// new one for every change and swaps it in (SnapshotSource); nothing here is ever
/// mutated from the main thread after init.
///
/// Buffers: two stereo pairs, A (index 0) and B (index 1). The tap's audio is copied
/// into A; each stage reads the current pair through the pull block and writes the
/// other, so the chain ping-pongs without copying.
final class RenderChain {
    let maxFrames: Int
    let slotIDs: [UUID]
    let inputLeft: UnsafeMutablePointer<Float>
    let inputRight: UnsafeMutablePointer<Float>

    private let units: [AUAudioUnit]                                   // keeps plugins alive
    private let renderBlocks: ContiguousArray<AURenderBlock>
    private let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>  // A.L, A.R, B.L, B.R
    private let source: UnsafeMutablePointer<Int>                      // pair the pull block reads
    private let outList: UnsafeMutableAudioBufferListPointer
    private let failed: OpaquePointer                                  // sc_flags, one per stage
    private let pull: AURenderPullInputBlock

    init(stages: [(slotID: UUID, unit: AUAudioUnit)], maxFrames: Int) {
        let buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 4)
        for i in 0..<4 {
            buffers[i] = .allocate(capacity: maxFrames)
            buffers[i].initialize(repeating: 0, count: maxFrames)
        }
        let source = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        source.initialize(to: 0)

        self.maxFrames = maxFrames
        slotIDs = stages.map(\.slotID)
        units = stages.map(\.unit)
        renderBlocks = ContiguousArray(stages.map { $0.unit.renderBlock })
        self.buffers = buffers
        self.source = source
        inputLeft = buffers[0]
        inputRight = buffers[1]
        outList = AudioBufferList.allocate(maximumBuffers: 2)
        failed = sc_flags_create(Int32(stages.count))

        // Captures only raw pointers, so calling it on the audio thread touches no refcounts.
        pull = { _, _, frameCount, _, ioData in
            let list = UnsafeMutableAudioBufferListPointer(ioData)
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            let base = source.pointee * 2
            for i in 0..<min(list.count, 2) {
                let from = UnsafeMutableRawPointer(buffers[base + i])
                if let to = list[i].mData {
                    if to != from { to.copyMemory(from: from, byteCount: byteCount) }
                } else {
                    list[i].mData = from
                }
                list[i].mDataByteSize = UInt32(byteCount)
            }
            return noErr
        }
    }

    deinit {
        for i in 0..<4 { buffers[i].deallocate() }
        buffers.deallocate()
        source.deallocate()
        free(outList.unsafeMutablePointer)
        sc_flags_destroy(failed)
    }

    var stageCount: Int { renderBlocks.count }

    /// Runs the chain over `frames` frames already in `inputLeft`/`inputRight` and
    /// returns the pair holding the result. A stage that returns an error is flagged
    /// and skipped from then on; its output is discarded. Audio-thread safe.
    func process(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>)
        -> (left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard frames > 0, frames <= maxFrames else { return (buffers[0], buffers[1]) }
        let byteCount = UInt32(frames * MemoryLayout<Float>.size)
        var current = 0
        for stage in 0..<renderBlocks.count {
            if sc_flags_get(failed, Int32(stage)) != 0 { continue }
            let target = 1 - current
            let dstL = buffers[target * 2], dstR = buffers[target * 2 + 1]
            outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: UnsafeMutableRawPointer(dstL))
            outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteCount, mData: UnsafeMutableRawPointer(dstR))
            source.pointee = current
            var flags = AudioUnitRenderActionFlags()
            let status = renderBlocks[stage](&flags, timestamp, AUAudioFrameCount(frames), 0,
                                             outList.unsafeMutablePointer, pull)
            if status != noErr {
                sc_flags_set(failed, Int32(stage))
                continue
            }
            // A plugin may point the list at its own buffers instead of filling ours.
            if let l = outList[0].mData, l != UnsafeMutableRawPointer(dstL) {
                dstL.update(from: l.assumingMemoryBound(to: Float.self), count: frames)
            }
            if let r = outList[1].mData, r != UnsafeMutableRawPointer(dstR) {
                dstR.update(from: r.assumingMemoryBound(to: Float.self), count: frames)
            }
            current = target
        }
        return (buffers[current * 2], buffers[current * 2 + 1])
    }

    /// Slots whose plugin returned a render error in this snapshot. Main thread.
    func failedSlotIDs() -> [UUID] {
        slotIDs.indices.filter { sc_flags_get(failed, Int32($0)) != 0 }.map { slotIDs[$0] }
    }
}
```

- [ ] **Step 5: Run the self-test**

Run: `swift build 2>&1 | grep error: ; swift run SoundChain --selftest`
Expected: every line `PASS`, final line `All self-tests passed.`, exit code 0 (`echo $?` → `0`).
If "restoring state brings the parameter back" fails while the others pass, print `mix.value` before and after and check whether AUDelay's bridged parameter tree needs `unit.parameterTree` re-fetched after `fullState` is set; fix the test, not by weakening the assertion.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add plugin host, render chain and --selftest

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Chain runner (snapshot build, publish, retire)

**Files:**
- Create: `Sources/SoundChain/SnapshotSource.swift`, `Sources/SoundChain/ChainRunner.swift`
- Modify: `Sources/SoundChain/SelfTest.swift` (add `runnerChecks`, call it from `run`)

**Interfaces:**
- Consumes: `Chain`, `ChainSlot`, `ComponentID` (Task 1); `LoadedPlugin`, `RenderFormat`, `RenderChain`, `SelfTest` helpers (Task 6); `sc_atomic_ptr_*` (Task 1).
- Produces:
  `struct SnapshotSource { let cell: OpaquePointer; static func make() -> SnapshotSource; func load() -> UnsafeMutableRawPointer? /* audio thread */; func swap(_ chain: RenderChain?) -> RenderChain? /* main thread */ }`;
  `final class ChainRunner { let source: SnapshotSource; var onChange: (() -> Void)?; private(set) var format: RenderFormat?; private(set) var componentFailures: [ComponentID: String]; var isLoading: Bool; var activeCount: Int; var retiredCount: Int; func sync(to: Chain); func setFormat(_: RenderFormat); func plugin(for: UUID) -> LoadedPlugin?; func error(for: UUID) -> String?; func captureState(for: UUID) -> Data?; @discardableResult func tick(now: Date = Date()) -> Bool }`.

- [ ] **Step 1: Add the failing self-test checks**

In `SelfTest.swift`, add this method and call it from `run()` right after `try renderChecks(check)` (inside the same `do`): `try runnerChecks(check)`.

```swift
    static func runnerChecks(_ check: (Bool, String) -> Void) throws {
        let runner = ChainRunner()
        runner.setFormat(RenderFormat(sampleRate: sampleRate, maxFrames: 4096))

        var chain = Chain()
        let delaySlot = chain.add(component: delay, name: "AUDelay", manufacturer: "Apple")
        chain.add(component: eq, name: "AUNBandEQ", manufacturer: "Apple")
        let missing = chain.add(component: ComponentID("aufx", "zzzz", "zzzz")!, name: "Missing", manufacturer: "Nobody")
        let garbled = chain.add(component: delay, name: "AUDelay (bad state)", manufacturer: "Apple")
        chain.setState(Data("not a plist".utf8), id: garbled.id)

        runner.sync(to: chain)
        check(spin { !runner.isLoading }, "runner finishes loading")
        check(runner.error(for: missing.id) != nil, "a missing plugin is flagged, not fatal")
        check(runner.componentFailures[missing.component] != nil, "a failed component is remembered for the picker")
        check(runner.plugin(for: garbled.id) != nil && runner.error(for: garbled.id) == nil,
              "unreadable saved state falls back to the plugin's defaults")
        check(runner.activeCount == 3, "the three loadable effects run")

        chain.setBypassed(true, id: delaySlot.id)
        runner.sync(to: chain)
        check(runner.activeCount == 2, "a bypassed slot is left out")

        chain.masterBypass = true
        runner.sync(to: chain)
        check(runner.activeCount == 0, "master bypass runs no effects")
        if let raw = runner.source.load() {
            let live = Unmanaged<RenderChain>.fromOpaque(raw).takeUnretainedValue()
            check(render(live, blocks: 2).0 == sine(block: 1), "master bypass passes audio through")
        } else {
            check(false, "a snapshot is published")
        }

        chain.masterBypass = false
        chain.remove(id: delaySlot.id)
        runner.sync(to: chain)
        check(runner.plugin(for: delaySlot.id) == nil, "a removed slot's plugin is released")
        check(runner.retiredCount > 0, "replaced snapshots are retired, not freed at once")
        runner.tick(now: Date().addingTimeInterval(ChainRunner.retireDelay + 1))
        check(runner.retiredCount == 0, "retired snapshots are freed after the delay")

        runner.setFormat(RenderFormat(sampleRate: 44_100, maxFrames: 4096))
        check(runner.plugin(for: garbled.id)?.preparedFormat?.sampleRate == 44_100,
              "a format change re-prepares loaded plugins")
    }
```

- [ ] **Step 2: Build to verify it fails**

Run: `swift build 2>&1 | grep error: | head -3`
Expected: `cannot find 'ChainRunner' in scope`.

- [ ] **Step 3: Implement the snapshot source**

`Sources/SoundChain/SnapshotSource.swift`:
```swift
import CAtomics
import Foundation

/// The one atomic pointer the IO proc reads the current RenderChain from.
/// The cell holds a +1 retain on the published snapshot.
struct SnapshotSource {
    let cell: OpaquePointer

    static func make() -> SnapshotSource { SnapshotSource(cell: sc_atomic_ptr_create()) }

    /// Audio thread: the published snapshot, unretained, or nil.
    @inline(__always)
    func load() -> UnsafeMutableRawPointer? { sc_atomic_ptr_load(cell) }

    /// Main thread: publishes `chain` and hands back the previous snapshot (with
    /// ownership). The caller must keep the old one alive until the audio thread
    /// can no longer be using it (ChainRunner.retireDelay).
    func swap(_ chain: RenderChain?) -> RenderChain? {
        let new = chain.map { Unmanaged.passRetained($0).toOpaque() }
        guard let old = sc_atomic_ptr_exchange(cell, new) else { return nil }
        return Unmanaged<RenderChain>.fromOpaque(old).takeRetainedValue()
    }
}
```

- [ ] **Step 4: Implement the runner**

`Sources/SoundChain/ChainRunner.swift`:
```swift
import AudioToolbox
import Foundation
import SoundChainCore

/// Main-thread owner of the loaded plugins. Turns a `Chain` into RenderChain
/// snapshots and publishes them to the audio thread through `source`.
final class ChainRunner {
    /// Replaced snapshots are freed after this long, far more than any IO cycle.
    static let retireDelay: TimeInterval = 1.0

    let source = SnapshotSource.make()
    /// Called after every publish and whenever errors change.
    var onChange: (() -> Void)?

    private(set) var format: RenderFormat?
    /// Components that failed to load this session, for flagging in the Add picker.
    private(set) var componentFailures: [ComponentID: String] = [:]

    private var chain = Chain()
    private var plugins: [UUID: LoadedPlugin] = [:]
    private var loading: Set<UUID> = []
    private var loadErrors: [UUID: String] = [:]
    private var renderErrors: [UUID: String] = [:]
    private var retired: [(chain: RenderChain, at: Date)] = []
    private var current: RenderChain?

    var isLoading: Bool { !loading.isEmpty }
    /// Effects actually running in the published snapshot.
    var activeCount: Int { current?.stageCount ?? 0 }
    var retiredCount: Int { retired.count }

    func plugin(for id: UUID) -> LoadedPlugin? { plugins[id] }
    func error(for id: UUID) -> String? { loadErrors[id] ?? renderErrors[id] }
    func captureState(for id: UUID) -> Data? { plugins[id]?.captureState() }

    /// Makes the running chain match `newChain`: releases removed plugins, loads new
    /// ones (restoring saved state), then publishes a new snapshot.
    func sync(to newChain: Chain) {
        chain = newChain
        let ids = Set(newChain.slots.map(\.id))
        for id in plugins.keys where !ids.contains(id) { plugins[id] = nil }
        loadErrors = loadErrors.filter { ids.contains($0.key) }
        renderErrors = renderErrors.filter { ids.contains($0.key) }
        for slot in newChain.slots
        where plugins[slot.id] == nil && !loading.contains(slot.id) && loadErrors[slot.id] == nil {
            load(slot)
        }
        publish()
    }

    /// Re-prepares every plugin for a new format. Precondition: no IO proc is running
    /// (TapEngine calls this between teardown and start). The published snapshot is
    /// withdrawn first anyway, so no plugin is re-prepared while it could be rendering.
    func setFormat(_ newFormat: RenderFormat) {
        guard newFormat != format else { return }
        if let old = source.swap(nil) { retired.append((old, Date())) }
        current = nil
        format = newFormat
        for (id, plugin) in plugins {
            do {
                try plugin.prepare(newFormat)
            } catch {
                plugins[id] = nil
                if let slot = chain.slot(id: id) { recordLoadFailure(slot, error) }
            }
        }
        publish()
    }

    /// Main thread, about once a second: frees retired snapshots and turns render
    /// errors reported by the audio thread into slot errors (rebuilding without those
    /// slots). Returns true when new errors appeared.
    @discardableResult
    func tick(now: Date = Date()) -> Bool {
        retired.removeAll { now.timeIntervalSince($0.at) >= Self.retireDelay }
        let failed = (current?.failedSlotIDs() ?? []).filter { renderErrors[$0] == nil }
        guard !failed.isEmpty else { return false }
        for id in failed { renderErrors[id] = "Stopped: the plugin reported a render error" }
        publish()
        return true
    }

    // MARK: Private

    private func load(_ slot: ChainSlot) {
        loading.insert(slot.id)
        LoadedPlugin.load(slot.component) { [weak self] result in
            guard let self else { return }
            self.loading.remove(slot.id)
            guard let latest = self.chain.slot(id: slot.id) else { return }   // removed while loading
            switch result {
            case .success(let plugin):
                if let state = latest.state {
                    do {
                        try plugin.restoreState(state)
                    } catch {
                        NSLog("SoundChain: %@ kept its default settings: %@", latest.name, error.localizedDescription)
                    }
                }
                if let format = self.format {
                    do {
                        try plugin.prepare(format)
                    } catch {
                        self.recordLoadFailure(latest, error)
                        self.publish()
                        return
                    }
                }
                self.plugins[slot.id] = plugin
            case .failure(let error):
                self.recordLoadFailure(latest, error)
            }
            self.publish()
        }
    }

    private func recordLoadFailure(_ slot: ChainSlot, _ error: Error) {
        let message = error.localizedDescription
        loadErrors[slot.id] = message
        componentFailures[slot.component] = message
    }

    private func publish() {
        guard let format else { onChange?(); return }
        let stages: [(slotID: UUID, unit: AUAudioUnit)] = chain.masterBypass ? [] : chain.slots.compactMap { slot in
            guard !slot.bypassed, renderErrors[slot.id] == nil, let plugin = plugins[slot.id] else { return nil }
            return (slotID: slot.id, unit: plugin.unit)
        }
        let next = RenderChain(stages: stages, maxFrames: format.maxFrames)
        if let old = source.swap(next) { retired.append((old, Date())) }
        current = next
        onChange?()
    }
}
```

- [ ] **Step 5: Run the self-test**

Run: `swift run SoundChain --selftest; echo "exit $?"`
Expected: every line `PASS`, `All self-tests passed.`, `exit 0`. The run also logs one `SoundChain: AUDelay (bad state) kept its default settings` line.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add chain runner that publishes render snapshots

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Core Audio tap engine and `--taptest`

**Files:**
- Create: `Sources/SoundChain/AudioHW.swift`, `Sources/SoundChain/AudioPermission.swift`, `Sources/SoundChain/TapEngine.swift`, `Sources/SoundChain/TapTest.swift`
- Modify: `Sources/SoundChain/main.swift`

**Interfaces:**
- Consumes: `SnapshotSource`, `ChainRunner`, `RenderFormat`, `RenderChain` (Tasks 6–7); `TapInput`, `ChannelMap`, `SampleGuard`, `Chain` (Core); `sc_counter_*`.
- Produces:
  `struct CoreAudioError: LocalizedError { let what: String; let status: OSStatus }`;
  `enum AudioHW { static func addr(_:_:) -> AudioObjectPropertyAddress; static func check(_:_:) throws; static func get<T>(_:_:initial:qualifier:qualifierSize:what:) throws -> T; static func string(_:_:what:) throws -> String; static func defaultOutputDevice() throws -> AudioObjectID; static func uid(_:) throws -> String; static func name(_:) -> String; static func nominalSampleRate(_:) throws -> Double; static func bufferFrameSize(_:) throws -> UInt32; static func setBufferFrameSize(_:_:) throws; static func ownProcessObject() throws -> AudioObjectID; static func tapFormat(_:) throws -> AudioStreamBasicDescription }`;
  `enum AudioPermission { enum Status { authorized, denied, unknown }; static func status() -> Status; static func request(_ completion: @escaping (Bool) -> Void); static func openSettings() }`;
  `@available(macOS 14.2, *) final class TapEngine { enum State: Equatable { stopped, running(device: String, sampleRate: Double, bufferFrames: Int), failed(String) }; private(set) var state: State; var onStateChange: ((State) -> Void)?; var onFormat: ((RenderFormat) -> Void)?; var callbackCount: Int64; init(source: SnapshotSource); func start(); func stop() }`;
  `@available(macOS 14.2, *) enum TapTest { static func run(seconds: Double) -> Bool }`.

This is hardware integration; the test is `--taptest` plus listening. **Keep the volume low for the first run**: if self-exclusion fails, the output is re-captured and feeds back.

- [ ] **Step 1: Write the tap test and entry point**

`Sources/SoundChain/TapTest.swift`:
```swift
import Foundation
import SoundChainCore

/// `SoundChain --taptest [seconds]`: runs the real tap with an empty (pass-through)
/// chain. Play audio while it runs: it must sound unchanged, with no echo, doubling
/// or feedback. Switch the output device mid-run to exercise the restart path.
@available(macOS 14.2, *)
enum TapTest {
    static func run(seconds: Double) -> Bool {
        let me = try? AudioHW.ownProcessObject()
        print("Own audio process object: \(me.map(String.init) ?? "NOT FOUND")")
        print("Capture permission: \(AudioPermission.status())")

        let runner = ChainRunner()
        runner.sync(to: Chain())
        let engine = TapEngine(source: runner.source)
        engine.onFormat = { runner.setFormat($0) }
        engine.onStateChange = { print("State: \($0)") }
        engine.start()

        var sawRunning = false
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            runner.tick()
            if case .running = engine.state { sawRunning = true }
        }
        let callbacks = engine.callbackCount
        engine.stop()
        print("IO callbacks: \(callbacks)")

        let ok = me != nil && sawRunning && callbacks > 0
        print(ok ? "Tap test passed." : "Tap test FAILED.")
        return ok
    }
}
```

`Sources/SoundChain/main.swift` (replace the whole file):
```swift
import Foundation
import StatusItemKit

LoginCLI.runIfRequested()

guard #available(macOS 14.2, *) else {
    FileHandle.standardError.write(Data("SoundChain needs macOS 14.2 or later.\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}
if let flag = arguments.firstIndex(of: "--taptest") {
    let seconds = arguments.dropFirst(flag + 1).first.flatMap(Double.init) ?? 5
    exit(TapTest.run(seconds: seconds) ? 0 : 1)
}
print("SoundChain: the menu-bar app arrives in Task 9. Try --selftest or --taptest.")
```

- [ ] **Step 2: Build to verify it fails**

Run: `swift build 2>&1 | grep error: | head -3`
Expected: `cannot find 'AudioHW' in scope`, `cannot find 'TapEngine' in scope`.

- [ ] **Step 3: Implement the Core Audio helpers**

`Sources/SoundChain/AudioHW.swift`:
```swift
import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let what: String
    let status: OSStatus
    var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
}

/// Thin wrappers over AudioObjectGet/SetPropertyData. Main thread.
enum AudioHW {
    static func addr(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError(what: what, status: status) }
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                       qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, what: String) throws -> T {
        var address = addr(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, &result), what)
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, what: String) throws -> String {
        var address = addr(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), what)
        guard let result else { throw CoreAudioError(what: what, status: kAudioHardwareUnspecifiedError) }
        return result.takeRetainedValue() as String
    }

    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func defaultOutputDevice() throws -> AudioObjectID {
        let id: AudioObjectID = try get(system, kAudioHardwarePropertyDefaultOutputDevice,
                                        initial: AudioObjectID(kAudioObjectUnknown), what: "Reading the default output")
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(what: "Finding an output device", status: kAudioHardwareBadDeviceError)
        }
        return id
    }

    static func uid(_ device: AudioObjectID) throws -> String {
        try string(device, kAudioDevicePropertyDeviceUID, what: "Reading the output's UID")
    }

    static func name(_ device: AudioObjectID) -> String {
        (try? string(device, kAudioObjectPropertyName, what: "Reading the output's name")) ?? "Unknown output"
    }

    static func nominalSampleRate(_ device: AudioObjectID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0), what: "Reading the sample rate")
    }

    static func bufferFrameSize(_ device: AudioObjectID) throws -> UInt32 {
        try get(device, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0), what: "Reading the buffer size")
    }

    static func setBufferFrameSize(_ device: AudioObjectID, _ frames: UInt32) throws {
        var address = addr(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value),
                  "Setting the buffer size")
    }

    /// SoundChain's own Core Audio process object, which the tap must exclude.
    /// Throws rather than return "unknown": tapping ourselves would feed back.
    static func ownProcessObject() throws -> AudioObjectID {
        var pid = getpid()
        let what = "Finding SoundChain's own audio process"
        let id: AudioObjectID = try withUnsafePointer(to: &pid) { pointer in
            try get(system, kAudioHardwarePropertyTranslatePIDToProcessObject,
                    initial: AudioObjectID(kAudioObjectUnknown),
                    qualifier: UnsafeRawPointer(pointer), qualifierSize: UInt32(MemoryLayout<pid_t>.size), what: what)
        }
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(what: what, status: kAudioHardwareIllegalOperationError)
        }
        return id
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription(), what: "Reading the tap format")
    }
}
```

- [ ] **Step 4: Implement the permission helper**

`Sources/SoundChain/AudioPermission.swift`:
```swift
import AppKit
import Foundation

/// System-audio capture permission ("System Audio Recording Only", under Privacy &
/// Security ▸ Screen & System Audio Recording). There is no public preflight API, so
/// this calls TCC's private functions through dlopen, as AudioCap does. If they
/// cannot be found the status is `.unknown` and the app simply tries the tap.
enum AudioPermission {
    enum Status { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static func status() -> Status {
        guard let handle = tcc, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not decided yet. `completion` runs on main.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle = tcc, let symbol = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
```

- [ ] **Step 5: Implement the tap engine**

`Sources/SoundChain/TapEngine.swift`:
```swift
import AppKit
import CAtomics
import CoreAudio
import Foundation
import SoundChainCore

/// Owns the global process tap, the private aggregate device that pairs it with the
/// current default output, and the IO proc that runs the chain. Main thread, except
/// `render`, which runs on the audio thread.
@available(macOS 14.2, *)
final class TapEngine {
    enum State: Equatable {
        case stopped
        case running(device: String, sampleRate: Double, bufferFrames: Int)
        case failed(String)
    }

    static let requestedBufferFrames: UInt32 = 512
    static let minimumMaxFrames = 4096

    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?
    /// Called with the format the chain must run at, while no IO is running.
    var onFormat: ((RenderFormat) -> Void)?

    private let source: SnapshotSource
    private let callbacks = sc_counter_create()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                             block: AudioObjectPropertyListenerBlock)] = []
    private var wakeObserver: NSObjectProtocol?
    private var restartPending = false
    private var restartForced = false

    init(source: SnapshotSource) { self.source = source }

    deinit {
        teardown()
        removeListeners()
        sc_counter_destroy(callbacks)
    }

    /// IO cycles run so far; for --taptest and diagnostics.
    var callbackCount: Int64 { sc_counter_get(callbacks) }

    /// Builds everything for the current default output and starts audio. On failure
    /// the state is `.failed` and listeners stay installed, so the next device change retries.
    func start() {
        teardown()
        removeListeners()
        do {
            try build()
        } catch {
            teardown()
            state = .failed(error.localizedDescription)
        }
        listen()
    }

    func stop() {
        teardown()
        removeListeners()
        state = .stopped
    }

    // MARK: Build and teardown

    private func build() throws {
        outputDevice = try AudioHW.defaultOutputDevice()
        let outputUID = try AudioHW.uid(outputDevice)
        let deviceName = AudioHW.name(outputDevice)
        let me = try AudioHW.ownProcessObject()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        description.uuid = UUID()
        description.name = "SoundChain"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try AudioHW.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the system audio tap")

        let tapFormat = try AudioHW.tapFormat(tapID)
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError(what: "Using the tap (it is not 32-bit float)", status: kAudioHardwareUnsupportedOperationError)
        }
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundChain",
            kAudioAggregateDeviceUIDKey: "com.nicholaspsmith.SoundChain.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try AudioHW.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                          "Creating the aggregate device")

        try? AudioHW.setBufferFrameSize(aggregateID, Self.requestedBufferFrames)
        let frames = Int(try AudioHW.bufferFrameSize(aggregateID))
        let rate = try AudioHW.nominalSampleRate(aggregateID)
        onFormat?(RenderFormat(sampleRate: rate, maxFrames: max(Self.minimumMaxFrames, frames)))

        let source = self.source, callbacks = self.callbacks
        try AudioHW.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, output, _ in
            sc_counter_increment(callbacks)
            TapEngine.render(source: source, interleaved: interleaved,
                             input: input, inputTime: inputTime, output: output)
        }, "Installing the audio callback")
        try AudioHW.check(AudioDeviceStart(aggregateID, procID), "Starting audio")
        state = .running(device: deviceName, sampleRate: rate, bufferFrames: frames)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Audio thread

    /// The IO proc body. No allocation, no locks: the snapshot is used unretained
    /// (it outlives any cycle; see ChainRunner.retireDelay).
    private static func render(source: SnapshotSource, interleaved: Bool,
                               input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>,
                               output: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard let raw = source.load() else { ChannelMap.zero(out); return }
        Unmanaged<RenderChain>.fromOpaque(raw)._withUnsafeGuaranteedRef { chain in
            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let frames = TapInput.read(inputList, interleaved: interleaved,
                                       left: chain.inputLeft, right: chain.inputRight, capacity: chain.maxFrames)
            guard frames > 0 else { ChannelMap.zero(out); return }
            let result = chain.process(frames: frames, timestamp: inputTime)
            SampleGuard.sanitize(left: result.left, right: result.right, frames: frames)
            ChannelMap.write(left: result.left, right: result.right, frames: frames, to: out)
        }
    }

    // MARK: Device changes

    private func listen() {
        addListener(AudioHW.system, kAudioHardwarePropertyDefaultOutputDevice)
        if outputDevice != kAudioObjectUnknown {
            addListener(outputDevice, kAudioDevicePropertyNominalSampleRate)
            addListener(outputDevice, kAudioDevicePropertyDeviceIsAlive)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart(force: true) }
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioHW.addr(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart(force: false) }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Debounces bursts of device notifications into one restart, and skips the
    /// restart when nothing that matters changed (building the aggregate itself can
    /// fire notifications; restarting on those would loop).
    private func scheduleRestart(force: Bool) {
        restartForced = restartForced || force
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let forced = self.restartForced
            self.restartPending = false
            self.restartForced = false
            if forced || self.needsRestart() { self.start() }
        }
    }

    private func needsRestart() -> Bool {
        guard case .running(_, let rate, _) = state else { return true }
        guard let current = try? AudioHW.defaultOutputDevice(), current == outputDevice else { return true }
        return (try? AudioHW.nominalSampleRate(outputDevice)) != rate
    }
}
```

- [ ] **Step 6: Build and run the tap test**

Run: `swift build 2>&1 | grep -E "error" ; swift run SoundChain --selftest | tail -1`
Expected: no errors; `All self-tests passed.`

Then, with **output volume low** and music playing (Music or a browser), run:
`swift run SoundChain --taptest 20`
The first run may show a macOS prompt asking to let **iTerm2** (the responsible process for a terminal launch) record system audio; allow it and rerun.
During the 20 s: listen (audio must sound exactly as before: no echo, doubling, silence, or rising feedback), and after ~5 s switch the output device in Control Center ▸ Sound (e.g. MacBook speakers ↔ Scarlett Solo), then switch back.
Expected output:
```
Own audio process object: <a number>
Capture permission: authorized
State: running(device: "...", sampleRate: 48000.0, bufferFrames: 512)
State: running(device: "<the other device>", ...)     ← after each switch, within ~1 s
IO callbacks: <thousands>
Tap test passed.
```
Exit code 0. If "Own audio process object: NOT FOUND", stop and report: do not work around it by dropping the exclusion (Review Focus 1).
If you hear echo or doubling, the originals are not being muted: check `muteBehavior` and that the aggregate lists the tap.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add Core Audio tap engine and --taptest

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Menu-bar app shell, bundle, install

**Files:**
- Create: `Sources/SoundChain/AppController.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `install.sh`
- Modify: `Sources/SoundChain/main.swift` (replace the final `print` with the app launch)

**Interfaces:**
- Consumes: `ChainStore`, `CrashGuard`, `Chain` (Core); `ChainRunner` (Task 7); `TapEngine`, `AudioPermission` (Task 8); StatusItemKit's `StatusItemController(pollInterval:onPoll:onBuildMenu:)`, `setIcon(_:)`, `MeterIcon.dot(color:)`, `YieldClient(item:)`, `LoginItem.isEnabled`, `LoginItem.toggle()`, `AppVersion.menuItem()`.
- Produces: `@available(macOS 14.2, *) final class AppController: NSObject, NSApplicationDelegate` with `private(set) var chain: Chain` and `func mutate(_ change: (inout Chain) -> Void)` (the only way the UI changes the chain: apply, save, `runner.sync`). Tasks 10–11 add to this class at the places marked `// Task 10` / `// Task 11` below.

- [ ] **Step 1: Write the app controller**

`Sources/SoundChain/AppController.swift`:
```swift
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
```

- [ ] **Step 2: Launch the app from `main.swift`**

In `Sources/SoundChain/main.swift`, replace the last line (`print("SoundChain: the menu-bar app arrives in Task 9. …")`) with:
```swift
import AppKit   // move this import to the top of the file with the others

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```
(Put `import AppKit` beside `import Foundation` at the top; the rest goes at the end.)

- [ ] **Step 3: Bundle files**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SoundChain</string>
	<key>CFBundleIdentifier</key>
	<string>com.nicholaspsmith.SoundChain</string>
	<key>CFBundleName</key>
	<string>SoundChain</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>StatusItemKitVersion</key>
	<string>0.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAudioCaptureUsageDescription</key>
	<string>SoundChain processes your Mac's audio through the effects you choose, then plays it back.</string>
</dict>
</plist>
```

`scripts/build-app.sh` (then `chmod +x`):
```bash
#!/bin/bash
# (MPL header)

set -euo pipefail
cd "$(dirname "$0")/.."
exec ../StatusItemKit/scripts/make-app.sh SoundChain SoundChain
```

`install.sh` (then `chmod +x`):
```bash
#!/bin/bash
# (MPL header)

# Build SoundChain.app and symlink it into ~/Applications (rebuilds propagate).
set -euo pipefail
cd "$(dirname "$0")"
scripts/build-app.sh
mkdir -p "$HOME/Applications"
ln -sfn "$PWD/build/SoundChain.app" "$HOME/Applications/SoundChain.app"
echo "Installed ~/Applications/SoundChain.app -> $PWD/build/SoundChain.app"
echo "Start at Login: use the menu, or run"
echo "    ~/Applications/SoundChain.app/Contents/MacOS/SoundChain --login on"
```

- [ ] **Step 4: Tag, build, install**

```bash
chmod +x scripts/build-app.sh install.sh
swift test 2>&1 | tail -2 && swift run SoundChain --selftest | tail -1
git add -A
git commit -m "Add menu-bar app shell, bundle and install script

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a v0.1.0 -m 0.1.0
./install.sh
```
Expected: tests and self-test pass; `==> Signed with stable identity …`; `Installed ~/Applications/SoundChain.app`.

- [ ] **Step 5: Verify by hand**

1. `open ~/Applications/SoundChain.app`. A dot appears in the menu bar (Barn may hide it; reveal Barn's block if needed). Allow the system-audio prompt if shown.
2. Play music. Expected: it sounds unchanged; the dot is green; the menu's first line reads like `MacBook Pro Speakers · 0 effects · 48 kHz / 512`.
3. Click **Bypass**. Expected: dot turns grey, first line says `bypassed`, audio unchanged. Click again: green.
4. **Permission denied (Review Focus 5):** in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, turn SoundChain off, then quit and reopen SoundChain. Expected: red dot, first line `System audio recording isn't allowed`, menu has **Grant System Audio Recording…** (opens that Settings pane) and **Retry**. Turn it back on, click **Retry**: green, audio flows.
5. **Crash fails open:** `pkill -9 SoundChain` while music plays. Expected: music continues unprocessed with at most a brief glitch.
6. **Crash loop:** reopen, `pkill -9 SoundChain` again, reopen. Expected on this third launch: grey dot, menu shows `Started bypassed after two crashes in a row`. Toggle Bypass off; quit normally with ⌘Q from the menu.
7. `cat ~/Library/Application\ Support/SoundChain/chain.json` shows `"masterBypass" : false` and `"slots" : [ ]`.

- [ ] **Step 6: Commit any fixes from verification**

```bash
git add -A && git diff --cached --quiet || git commit -m "Fix issues found in app-shell verification

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Chain window and Add picker

**Files:**
- Create: `Sources/SoundChain/ComponentScanner.swift`, `Sources/SoundChain/ChainWindow.swift`, `Sources/SoundChain/AddEffectPicker.swift`
- Modify: `Sources/SoundChain/AppController.swift` (the `// Task 10` markers)

**Interfaces:**
- Consumes: `CatalogEntry`, `PluginCatalog`, `ChainSlot`, `Chain.move/remove/add/setBypassed` (Core); `ChainRunner.error(for:)`, `componentFailures` (Task 7); `AppController.mutate` (Task 9).
- Produces:
  `enum ComponentScanner { static func effects(failures: [ComponentID: String]) -> [CatalogEntry] }`;
  `final class ChainWindowController: NSWindowController { struct Row: Equatable { var slot: ChainSlot; var error: String? }; var rows: () -> [Row]; var catalog: () -> [CatalogEntry]; var onBypass: (UUID, Bool) -> Void /* (id, bypassed) */; var onMove: (Int, Int) -> Void /* (from, insertionIndex) */; var onRemove: (UUID) -> Void; var onAdd: (CatalogEntry) -> Void; var onOpen: (UUID) -> Void; var canOpen: Bool; func present(); func reload() }`;
  `final class AddEffectViewController: NSViewController { init(entries: [CatalogEntry], onPick: @escaping (CatalogEntry) -> Void) }`.

- [ ] **Step 1: Installed-effects scanner**

`Sources/SoundChain/ComponentScanner.swift`:
```swift
import AVFoundation
import AudioToolbox
import SoundChainCore

enum ComponentScanner {
    /// Every installed effect Audio Unit (plain and MIDI-controlled effects), flagged
    /// with any load error seen this session.
    static func effects(failures: [ComponentID: String]) -> [CatalogEntry] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type -> [CatalogEntry] in
            let query = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                  componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            return AVAudioUnitComponentManager.shared().components(matching: query).map { component in
                let id = ComponentID(component.audioComponentDescription)
                return CatalogEntry(component: id, name: component.name,
                                    manufacturer: component.manufacturerName, loadError: failures[id])
            }
        }
    }
}
```

- [ ] **Step 2: Chain window**

`Sources/SoundChain/ChainWindow.swift`:
```swift
import AppKit
import SoundChainCore

/// The chain editor: a drag-to-reorder list of effects with bypass checkboxes and
/// Open buttons, plus Add… and –. Holds no chain state; it asks `rows()` on reload.
final class ChainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    struct Row: Equatable {
        var slot: ChainSlot
        var error: String?
    }

    var rows: () -> [Row] = { [] }
    var catalog: () -> [CatalogEntry] = { [] }
    var onBypass: (UUID, Bool) -> Void = { _, _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onAdd: (CatalogEntry) -> Void = { _ in }
    var onOpen: (UUID) -> Void = { _ in }
    /// False until editor windows exist (Task 11).
    var canOpen = false

    private static let dragType = NSPasteboard.PasteboardType("com.nicholaspsmith.SoundChain.row")
    private let table = NSTableView()
    private let removeButton = NSButton(title: "–", target: nil, action: nil)
    private var current: [Row] = []
    private var addPopover: NSPopover?

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
        }
        removeButton.isEnabled = current.indices.contains(table.selectedRow)
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
        let buttons = NSStackView(views: [addButton, removeButton])
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = current.indices.contains(table.selectedRow)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
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
        onRemove(current[table.selectedRow].slot.id)
    }

    @objc private func showAdd(_ sender: NSButton) {
        let picker = AddEffectViewController(entries: catalog()) { [weak self] entry in
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

        let open = NSButton(title: "Open", target: self, action: #selector(openTapped))
        open.isEnabled = canOpen && row.error == nil

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [handle, text, spacer, open])
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
```

- [ ] **Step 3: Add picker**

`Sources/SoundChain/AddEffectPicker.swift`:
```swift
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
    private let onPick: (CatalogEntry) -> Void
    private var items: [Item] = []
    private let search = NSSearchField()
    private let table = NSTableView()

    init(entries: [CatalogEntry], onPick: @escaping (CatalogEntry) -> Void) {
        self.entries = entries
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
        items = PluginCatalog.groups(entries, search: search.stringValue).flatMap { group in
            [Item.header(group.manufacturer)] + group.entries.map(Item.entry)
        }
        table.reloadData()
        if let first = items.indices.first(where: isPickable) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
    }

    private func isPickable(_ row: Int) -> Bool {
        guard items.indices.contains(row), case .entry(let entry) = items[row] else { return false }
        return entry.loadError == nil
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
            let label = NSTextField(labelWithString: entry.loadError.map { "\(entry.name) — \($0)" } ?? entry.name)
            label.textColor = entry.loadError == nil ? .labelColor : .systemRed
            label.lineBreakMode = .byTruncatingTail
            return label
        }
    }
}
```

- [ ] **Step 4: Wire it into the app controller**

In `AppController.swift`:

Add a property next to the others:
```swift
    private var chainWindow: ChainWindowController?
```

Replace `// Task 10: chain window reload goes here.` with:
```swift
        chainWindow?.reload()
```

Replace `// Task 10: "Edit Chain…" goes here.` with:
```swift
        menu.addItem(item("Edit Chain…", #selector(editChain), key: "e"))
```

Add these methods (in the `// MARK: Menu` section):
```swift
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
        window.onRemove = { [unowned self] id in self.mutate { $0.remove(id: id) } }
        window.onAdd = { [unowned self] entry in
            self.mutate { $0.add(component: entry.component, name: entry.name, manufacturer: entry.manufacturer) }
        }
        // Task 11: onOpen / canOpen wiring goes here.
        return window
    }
```

- [ ] **Step 5: Build, install, verify by hand**

```bash
swift test 2>&1 | tail -2 && ./install.sh && pkill -x SoundChain; open ~/Applications/SoundChain.app
```
With music playing:
1. Menu ▸ **Edit Chain…** (⌘E). Window opens, empty.
2. **Add…**, type `delay`, press Return. Expected: AUDelay row appears; audio gains an echo within a second; menu line says `1 effect`.
3. Add `AUNBandEQ` the same way. Drag it above AUDelay. Expected: order changes and survives reopening the window.
4. Uncheck AUDelay. Expected: echo stops; menu says `1 effect`. Re-check it: echo returns.
5. Add any **Waves** plugin (they fail with -10875 on this Mac). Expected: its row shows a red error, the dot turns red, the menu lists the error, other effects keep working. Open **Add…** again: that Waves entry is red and cannot be picked.
6. Select the Waves row, click **–**. Expected: row gone, dot green again.
7. `cat ~/Library/Application\ Support/SoundChain/chain.json`: slots in the displayed order with the right `bypassed` values. Quit and relaunch: the chain comes back and the echo resumes.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add chain window and searchable Add picker

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Plugin editor windows and settings capture

**Files:**
- Create: `Sources/SoundChain/EditorWindows.swift`
- Modify: `Sources/SoundChain/AppController.swift` (the `// Task 11` markers, `onRemove`)

**Interfaces:**
- Consumes: `ChainRunner.plugin(for:)`, `captureState(for:)` (Task 7); `Chain.setState` (Task 1); `ChainWindowController.onOpen`, `canOpen` (Task 10).
- Produces: `final class EditorWindows: NSObject, NSWindowDelegate { var onClose: (UUID) -> Void; var openSlotIDs: [UUID]; func open(slotID: UUID, title: String, unit: AUAudioUnit); func close(slotID: UUID); func closeAll() }`.

- [ ] **Step 1: Editor windows**

`Sources/SoundChain/EditorWindows.swift`:
```swift
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
```

- [ ] **Step 2: Wire editors and settings capture into the app controller**

In `AppController.swift`:

Add properties:
```swift
    private let editors = EditorWindows()
    private var lastEditorCapture = Date()
    static let editorCaptureInterval: TimeInterval = 5
```

Replace `// Task 11: editor wiring goes here.` with:
```swift
        editors.onClose = { [weak self] id in self?.captureState(id) }
```

Replace `// Task 11: close editors here, before states are captured.` with:
```swift
        editors.closeAll()
```

Replace `// Task 11: periodic editor state capture goes here.` with:
```swift
        if !editors.openSlotIDs.isEmpty,
           Date().timeIntervalSince(lastEditorCapture) >= Self.editorCaptureInterval {
            lastEditorCapture = Date()
            editors.openSlotIDs.forEach(captureState)
        }
```

Replace `// Task 11: onOpen / canOpen wiring goes here.` with:
```swift
        window.canOpen = true
        window.onOpen = { [unowned self] id in self.openEditor(id) }
```

Change the existing `window.onRemove` line to close the editor first:
```swift
        window.onRemove = { [unowned self] id in
            self.editors.close(slotID: id)
            self.mutate { $0.remove(id: id) }
        }
```

Add these methods (in `// MARK: Chain changes`):
```swift
    private func openEditor(_ id: UUID) {
        guard let slot = chain.slot(id: id), let plugin = runner.plugin(for: id) else { return }
        editors.open(slotID: id, title: "\(slot.name) — \(slot.manufacturer)", unit: plugin.unit)
    }

    /// Stores a plugin's current settings, saving only if they changed.
    private func captureState(_ id: UUID) {
        guard let data = runner.captureState(for: id) else { return }
        if chain.setState(data, id: id) { save() }
    }
```

- [ ] **Step 3: Build, install, verify by hand**

```bash
swift test 2>&1 | tail -2 && ./install.sh && pkill -x SoundChain; open ~/Applications/SoundChain.app
```
With music playing and AUDelay in the chain:
1. Edit Chain… ▸ AUDelay ▸ **Open**. Expected: a floating panel titled `AUDelay — Apple` with its controls; clicking Open again focuses the same panel.
2. Note the file hash: `shasum ~/Library/Application\ Support/SoundChain/chain.json`. Move Delay Time noticeably. Close the panel. Expected: the echo timing changed as you moved it; the hash is now different.
3. Reopen the panel, change Delay Time, wait 6 s without closing. Expected: hash changes again (periodic capture).
4. With the panel open, quit with ⌘Q from the menu. Relaunch, reopen the editor. Expected: Delay Time is where you left it.
5. Add **Ozone 9 Elements** (or another third-party effect) and Open it. Expected: its own UI appears and changes are audible.
6. Add **AUBandpass** (no custom UI) and Open it. Expected: a generic parameter panel with sliders.
7. With an editor open, remove that slot with **–**. Expected: the panel closes and nothing crashes.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add plugin editor windows and settings capture

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: README, end-to-end checklist, release tag

**Files:**
- Create: `README.md`, `docs/e2e-checklist.md`

**Interfaces:** none (documentation and verification).

- [ ] **Step 1: Write the README**

`README.md`:
```markdown
# SoundChain

Part of the [Menubarn](https://widgets.nicksmith.software) widget library.

A menu-bar app that runs one chain of Audio Unit effects over all of your Mac's
audio: EQ, room correction, loudness, anything installed as an AU effect. Pick
effects, open their own editors, and the processed sound plays through whatever
output is current.

## Requirements

- macOS 14.2 or later (Core Audio process taps).
- Audio Unit effects (AUv2 or AUv3). VST3 is not supported.

## Install

    ./install.sh

Builds `build/SoundChain.app` (via StatusItemKit's `make-app.sh`) and symlinks it
into `~/Applications`. On first launch, allow **System Audio Recording** when asked.
Start at Login is in the menu, or `SoundChain --login on`.

## Use

- **Bypass** (⌘B) turns all processing off; audio passes through untouched.
- **Edit Chain…** (⌘E) opens the chain: **Add…** searches installed effects, drag
  rows to reorder, uncheck to bypass one effect, **Open** shows its editor, **–**
  removes it.
- The dot is green when processing, grey when bypassed, red on an error (the menu
  says what).

Settings are saved to `~/Library/Application Support/SoundChain/chain.json`,
including each plugin's own state.

## How it works

A global Core Audio process tap captures every app's output except SoundChain's own
and mutes the originals. The tap and the current default output device are joined in
a private aggregate device, whose IO callback runs the effects in order and writes
the result to the output. Chain edits build a new immutable render snapshot on the
main thread and swap it in atomically, so the audio thread never waits.

If SoundChain crashes, the private tap and aggregate disappear with it and macOS
plays your audio unprocessed. Two crashes in a row start the next launch bypassed.

## Troubleshooting

- `SoundChain --selftest` renders through Apple's AUs offline and checks the chain.
- `SoundChain --taptest 20` runs the real tap with no effects for 20 seconds.
- A plugin that fails to open (for example, an unlicensed Waves plugin) stays in the
  chain in red and is skipped; its settings are kept.

## Why not a SwiftBar plugin?

A shell plugin cannot host Audio Units, run a real-time audio callback, or show a
plugin's editor window. This needs a native process.
```

- [ ] **Step 2: Write the end-to-end checklist**

`docs/e2e-checklist.md`:
```markdown
# SoundChain end-to-end checklist

Run with music playing. Record the date, macOS version and result of each step.

1. Fresh start: move `~/Library/Application Support/SoundChain` aside, launch. Permission prompt appears; allow it. Green dot, audio unchanged.
2. Add AUDelay; echo is audible. Bypass on/off from the menu works.
3. Reorder two effects by dragging; order persists across relaunch.
4. Switch output between the built-in speakers and the Scarlett Solo (and back) while playing. Audio follows within about a second each time; no restart loop in the menu status.
5. Sleep the Mac for at least one minute, wake it. Audio resumes processed without touching SoundChain.
6. `pkill -9 SoundChain`: unprocessed audio continues.
7. Relaunch: chain and each plugin's settings are restored (open an editor to confirm).
8. Corrupt the chain file (`echo junk > ~/Library/Application\ Support/SoundChain/chain.json`), relaunch: empty chain, menu names the `.corrupt-` backup file.
9. Restore the moved-aside folder from step 1.
```

- [ ] **Step 3: Run the checklist**

Work through `docs/e2e-checklist.md` and append a results section to that file (date, `sw_vers -productVersion`, pass/fail per step, notes). Any failure: fix it (with its own commit) before tagging.

- [ ] **Step 4: Final checks and tag**

```bash
swift test 2>&1 | tail -2
swift run SoundChain --selftest | tail -1
git add -A
git commit -m "Add README and end-to-end checklist results

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag -a v0.1.1 -m 0.1.1
./install.sh
```
Expected: tests and self-test pass; the installed app reports version 0.1.1 in its menu. Do not push.

- [ ] **Step 5: Record the project in memory**

Write a project memory (`~/.claude/projects/-Users-nicholassmith/memory/project_soundchain.md`, plus its `MEMORY.md` line) noting: repo path, local-only (not pushed), what it does, the `--selftest`/`--taptest` flags, that Waves AUs fail with -10875 on this Mac, and that the Menubarn polish step (mascot, character icon, app icon, site entry, global CLAUDE.md app list) is still to do.
