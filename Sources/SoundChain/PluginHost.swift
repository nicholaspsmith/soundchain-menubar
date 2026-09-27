// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Nicholas Smith

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

    /// Out-of-process plugins answer property reads over XPC, which can stall.
    var isOutOfProcess: Bool { !unit.isLoadedInProcess }

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
        // The AUv2 bridge leaves the input bus disabled; rendering then fails with
        // kAudioUnitErr_NoConnection (-10876) and the pull block is never called.
        unit.inputBusses[0].isEnabled = true
        unit.outputBusses[0].isEnabled = true
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
