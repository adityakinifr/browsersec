//
//  NeuralSeparator.swift
//  LiveKaraoke — M4
//
//  Higher-quality vocal removal via a Core ML source-separation model, run
//  block-by-block off the render thread. This is the quality tier of the
//  design's "two latency domains": neural adds latency, so it lives on the
//  backing-track path only (never in the singer's monitoring loop).
//
//  The model is NOT bundled (it's large and license-bound). Convert one with
//  `tools/convert_separator_coreml.py` and drop `VocalSeparator.mlpackage` into
//  the app target. Until then `isAvailable == false` and the app uses the
//  band-split remover.
//
//  Expected model contract (see tools/README.md):
//    input  "audioIn"  : MLMultiArray  Float32  shape [1, 2, blockSize]  (L,R)
//    output "accompaniment" : MLMultiArray Float32 shape [1, 2, blockSize]
//

import Foundation
import CoreML

enum SeparationMethod: String, CaseIterable, Identifiable {
    case bandSplit = "Band-split (fast)"
    case neural = "Neural (Core ML)"
    var id: String { rawValue }
}

final class NeuralSeparator {
    /// Frames per inference call. Must match the converted model's window.
    let blockSize = 1024

    private let model: MLModel?
    private let inputName = "audioIn"
    private let outputName = "accompaniment"
    private var inputArray: MLMultiArray?

    var isAvailable: Bool { model != nil }

    init() {
        // Look for a compiled or packaged model in the app bundle.
        let candidates = ["VocalSeparator"]
        var loaded: MLModel?
        let config = MLModelConfiguration()
        config.computeUnits = .all      // prefer the Neural Engine
        for name in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlpackage") {
                loaded = try? MLModel(contentsOf: url, configuration: config)
                if loaded != nil { break }
            }
        }
        self.model = loaded
        if loaded != nil {
            self.inputArray = try? MLMultiArray(
                shape: [1, 2, NSNumber(value: blockSize)], dataType: .float32)
        }
    }

    func reset() { /* stateless block model; nothing to reset */ }

    /// One stereo block (interleaved L,R, `blockSize` frames) -> mono instrumental.
    /// Falls back to a plain downmix if the model is unavailable or errors.
    func process(stereoInterleaved input: UnsafeBufferPointer<Float>,
                 out: UnsafeMutableBufferPointer<Float>) {
        guard let model, let inputArray else {
            downmix(input, into: out); return
        }

        // Pack interleaved [L,R,...] into channels-first [1,2,N].
        let ptr = inputArray.dataPointer.bindMemory(to: Float.self, capacity: 2 * blockSize)
        for f in 0..<blockSize {
            ptr[f] = input[f * 2]                 // channel 0 (L)
            ptr[blockSize + f] = input[f * 2 + 1] // channel 1 (R)
        }

        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)])
            let result = try model.prediction(from: provider)
            guard let acc = result.featureValue(for: outputName)?.multiArrayValue else {
                downmix(input, into: out); return
            }
            let a = acc.dataPointer.bindMemory(to: Float.self, capacity: 2 * blockSize)
            // Downmix the accompaniment stereo output to mono.
            for f in 0..<blockSize {
                out[f] = (a[f] + a[blockSize + f]) * 0.5
            }
        } catch {
            downmix(input, into: out)
        }
    }

    private func downmix(_ input: UnsafeBufferPointer<Float>,
                         into out: UnsafeMutableBufferPointer<Float>) {
        for f in 0..<blockSize {
            out[f] = (input[f * 2] + input[f * 2 + 1]) * 0.5
        }
    }
}
