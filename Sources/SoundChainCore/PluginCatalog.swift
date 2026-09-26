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
