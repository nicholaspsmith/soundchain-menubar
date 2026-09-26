// swift-tools-version:5.9
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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
