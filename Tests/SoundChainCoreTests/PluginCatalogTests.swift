// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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

final class PluginCatalogPinningTests: XCTestCase {
    private func entry(_ name: String, _ maker: String, _ sub: String, disabled: Bool = false) -> CatalogEntry {
        var e = CatalogEntry(component: ComponentID("aufx", sub, "test")!, name: name, manufacturer: maker)
        e.disabled = disabled
        return e
    }

    private lazy var all: [CatalogEntry] = [
        entry("Pro-C 2", "FabFilter", "proc"),
        entry("Nectar 3", "iZotope", "nec3"),
        entry("Pro-L 2", "FabFilter", "prol"),
        entry("Vinyl", "iZotope", "vnyl"),
        entry("Pro-Q 3", "FabFilter", "proq"),
    ]
    private let pins = ["Pro-Q", "Pro-L 2", "Nectar 3"]

    private func shape(_ groups: [CatalogGroup]) -> [String] {
        groups.map { "\($0.manufacturer): \($0.entries.map(\.name).joined(separator: ", "))" }
    }

    func testPinnedEffectsComeFirstInPinOrderAndLeaveTheirMakerGroup() {
        XCTAssertEqual(shape(PluginCatalog.groups(all, pinned: pins)), [
            "\(PluginCatalog.pinnedGroupName): Pro-Q 3, Pro-L 2, Nectar 3",
            "FabFilter: Pro-C 2",
            "iZotope: Vinyl",
        ])
    }

    func testPinsMatchNamePrefixesCaseInsensitively() {
        XCTAssertEqual(PluginCatalog.groups(all, pinned: ["pro-q"]).first?.entries.map(\.name), ["Pro-Q 3"])
    }

    func testSearchAppliesToPinnedEffects() {
        XCTAssertEqual(shape(PluginCatalog.groups(all, search: "nectar", pinned: pins)),
                       ["\(PluginCatalog.pinnedGroupName): Nectar 3"])
    }

    func testNoPinsMeansNoPinnedGroup() {
        XCTAssertFalse(PluginCatalog.groups(all).contains { $0.manufacturer == PluginCatalog.pinnedGroupName })
    }

    func testDisabledEffectsGoInTheLastGroupEvenWhenPinned() {
        let entries = all + [entry("MCompressor", "MeldaProduction", "mcmp", disabled: true),
                             entry("Nectar 3", "iZotope", "nec3", disabled: true)]
        var withNectarDisabled = entries
        withNectarDisabled.removeAll { $0.name == "Nectar 3" && !$0.disabled }
        let groups = PluginCatalog.groups(withNectarDisabled, pinned: pins)
        XCTAssertEqual(groups.last?.manufacturer, PluginCatalog.disabledGroupName)
        XCTAssertEqual(groups.last?.entries.map(\.name), ["MCompressor", "Nectar 3"])
        XCTAssertEqual(groups.first?.entries.map(\.name), ["Pro-Q 3", "Pro-L 2"])
        XCTAssertFalse(groups.dropLast().contains { $0.entries.contains(where: \.disabled) })
    }
}
