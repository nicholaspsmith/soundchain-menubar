// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
    /// A name the user gave this effect ("Pitch Down"), or nil. Chains saved
    /// before 1.8.0 have no such key and decode with nil.
    public var customName: String?

    public init(id: UUID = UUID(), component: ComponentID, name: String, manufacturer: String,
                bypassed: Bool = false, state: Data? = nil, customName: String? = nil) {
        self.id = id
        self.component = component
        self.name = name
        self.manufacturer = manufacturer
        self.bypassed = bypassed
        self.state = state
        self.customName = ChainSlot.normalized(customName)
    }

    /// What to call this effect: its custom name when it has one, else the plugin's name.
    public var displayName: String { customName ?? name }

    /// Trims whitespace; an empty result means no custom name.
    public static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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

    /// Names slot `id` (trimmed); an empty or blank name clears it. Returns true
    /// only when the stored name changed.
    @discardableResult
    public mutating func setCustomName(_ name: String?, id: UUID) -> Bool {
        let name = ChainSlot.normalized(name)
        guard let i = slots.firstIndex(where: { $0.id == id }), slots[i].customName != name else { return false }
        slots[i].customName = name
        return true
    }

    /// Stores a plugin's state. Returns true only when the stored value changed.
    @discardableResult
    public mutating func setState(_ state: Data?, id: UUID) -> Bool {
        guard let i = slots.firstIndex(where: { $0.id == id }), slots[i].state != state else { return false }
        slots[i].state = state
        return true
    }
}

/// A copied slot: everything that makes an effect except its identity, so each
/// paste or duplicate becomes a new, independent instance. This is what ⌘C puts
/// on the pasteboard (as JSON, under `pasteboardType`).
public struct SlotCopy: Codable, Equatable, Sendable {
    public static let pasteboardType = "com.nicholaspsmith.SoundChain.slot"
    public static let currentVersion = 1

    public var version: Int
    public var component: ComponentID
    public var name: String
    public var manufacturer: String
    public var bypassed: Bool
    /// The plugin's `fullState`, as a binary property list.
    public var state: Data?
    /// The slot's custom name; absent in copies made before 1.8.0.
    public var customName: String?

    /// Copies `slot`. `liveState` is the running plugin's current settings; when
    /// nil (not loaded, or it did not answer) the slot's saved settings are used.
    public init(_ slot: ChainSlot, liveState: Data? = nil) {
        version = Self.currentVersion
        component = slot.component
        name = slot.name
        manufacturer = slot.manufacturer
        bypassed = slot.bypassed
        state = liveState ?? slot.state
        customName = slot.customName
    }

    /// A new slot (fresh id) with these settings.
    public func makeSlot() -> ChainSlot {
        ChainSlot(component: component, name: name, manufacturer: manufacturer, bypassed: bypassed, state: state,
                  customName: customName)
    }

    public func encoded() -> Data {
        // Encoding plain values and Data cannot fail.
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Nil for anything that is not a copy this version of SoundChain can read.
    public init?(encoded data: Data) {
        guard let copy = try? JSONDecoder().decode(SlotCopy.self, from: data),
              copy.version <= Self.currentVersion else { return nil }
        self = copy
    }
}

extension Chain {
    /// Appends a copy of slot `id` to the end of the chain. `liveState` is the
    /// running plugin's current settings (the saved ones are used when nil).
    /// Returns the new slot, or nil if `id` is not in the chain.
    @discardableResult
    public mutating func duplicate(id: UUID, liveState: Data? = nil) -> ChainSlot? {
        guard let slot = slot(id: id) else { return nil }
        let copy = SlotCopy(slot, liveState: liveState).makeSlot()
        slots.append(copy)
        return copy
    }

    /// Inserts `copy` as a new slot directly below slot `id`, or at the end when
    /// `id` is nil or not in the chain. Returns the new slot.
    @discardableResult
    public mutating func insert(_ copy: SlotCopy, below id: UUID?) -> ChainSlot {
        let slot = copy.makeSlot()
        if let id, let i = slots.firstIndex(where: { $0.id == id }) {
            slots.insert(slot, at: i + 1)
        } else {
            slots.append(slot)
        }
        return slot
    }
}
