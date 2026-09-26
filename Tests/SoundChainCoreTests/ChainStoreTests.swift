// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
