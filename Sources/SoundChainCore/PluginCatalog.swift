// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

import Foundation

/// An installed effect as the Add picker shows it.
public struct CatalogEntry: Hashable, Sendable {
    public var component: ComponentID
    public var name: String
    public var manufacturer: String
    /// Why this plugin failed to load earlier in this session; nil if it has not failed.
    public var loadError: String?
    /// True once this plugin has crashed SoundChain: it is listed last and cannot be picked.
    public var disabled: Bool

    public init(component: ComponentID, name: String, manufacturer: String, loadError: String? = nil,
                disabled: Bool = false) {
        self.component = component
        self.name = name
        self.manufacturer = manufacturer
        self.loadError = loadError
        self.disabled = disabled
    }
}

public struct CatalogGroup: Equatable, Sendable {
    public var manufacturer: String
    public var entries: [CatalogEntry]
}

public enum PluginCatalog {
    public static let pinnedGroupName = "Pinned"
    public static let disabledGroupName = "Disabled after a crash"

    /// Groups entries by manufacturer (groups and names sorted case-insensitively),
    /// keeping only those where every whitespace-separated search term appears in
    /// the name or manufacturer. Unloadable entries stay in, flagged by `loadError`.
    /// Entries with the same component are collapsed to the first.
    ///
    /// Entries whose name starts with one of `pinned` (case-insensitive) move to a
    /// first "Pinned" group, in pin order. Disabled entries move to a last group,
    /// whatever else applies to them.
    public static func groups(_ entries: [CatalogEntry], search: String = "",
                              pinned: [String] = []) -> [CatalogGroup] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<ComponentID>()
        let matching = entries.filter { entry in
            guard seen.insert(entry.component).inserted else { return false }
            return terms.allSatisfy { term in
                entry.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || entry.manufacturer.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        func pinIndex(_ entry: CatalogEntry) -> Int? {
            pinned.firstIndex { PinList.matches(entry.name, $0) }
        }
        let byName: (CatalogEntry, CatalogEntry) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let disabled = matching.filter(\.disabled).sorted(by: byName)
        let enabled = matching.filter { !$0.disabled }
        let pinnedEntries = enabled.compactMap { e in pinIndex(e).map { (e, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : byName($0.0, $1.0) }
            .map(\.0)
        let rest = enabled.filter { pinIndex($0) == nil }

        var result: [CatalogGroup] = []
        if !pinnedEntries.isEmpty { result.append(CatalogGroup(manufacturer: pinnedGroupName, entries: pinnedEntries)) }
        result += makerGroups(rest)
        if !disabled.isEmpty { result.append(CatalogGroup(manufacturer: disabledGroupName, entries: disabled)) }
        return result
    }

    private static func makerGroups(_ matching: [CatalogEntry]) -> [CatalogGroup] {
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

/// The user's pinned effects: name prefixes, matched case-insensitively from the
/// start of the name ("Pro-Q" pins "Pro-Q 3" and a future "Pro-Q 4").
public enum PinList {
    static func matches(_ name: String, _ pin: String) -> Bool {
        name.range(of: pin, options: [.caseInsensitive, .anchored]) != nil
    }

    public static func isPinned(_ name: String, in pins: [String]) -> Bool {
        pins.contains { matches(name, $0) }
    }

    /// Adds `name` itself, unless a pin already covers it.
    public static func pin(_ name: String, in pins: [String]) -> [String] {
        isPinned(name, in: pins) ? pins : pins + [name]
    }

    /// Removes every pin that covers `name`.
    public static func unpin(_ name: String, in pins: [String]) -> [String] {
        pins.filter { !matches(name, $0) }
    }

    public static func toggle(_ name: String, in pins: [String]) -> [String] {
        isPinned(name, in: pins) ? unpin(name, in: pins) : pin(name, in: pins)
    }
}
