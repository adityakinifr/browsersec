//
//  AudioMonitor.swift
//  LiveKaraoke
//
//  Pulls captured *interleaved stereo* samples from the ring buffer, runs the
//  M1 vocal remover to produce a mono instrumental, and plays it to the default
//  output via AVAudioEngine. Use headphones — monitoring through speakers while
//  capturing system audio causes feedback.
//

import AVFoundation

final class AudioMonitor {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: FloatRingBuffer
    private let sampleRate: Double
    private let remover: VocalRemover

    /// Toggle vocal removal live (true = instrumental, false = full mix).
    var removeVocals: Bool {
        get { remover.enabled }
        set { remover.enabled = newValue }
    }

    init(ring: FloatRingBuffer, sampleRate: Double, removeVocals: Bool) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.remover = VocalRemover(sampleRate: sampleRate)
        self.remover.enabled = removeVocals
    }

    func start() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1) else {
            throw NSError(domain: "LiveKaraoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad monitor format"])
        }

        let ring = self.ring
        let remover = self.remover
        // Scratch for one render quantum of interleaved stereo. Sized generously;
        // AVAudioSourceNode quanta are typically <= 512 frames.
        let maxFrames = 4096
        let stereoScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxFrames * 2)
        stereoScratch.initialize(repeating: 0)

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = abl.first,
                  let out = buf.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let n = Int(frameCount)
            let want = min(n, maxFrames)
            let slice = UnsafeMutableBufferPointer(start: stereoScratch.baseAddress, count: want * 2)
            ring.read(into: slice)

            for f in 0..<want {
                let l = stereoScratch[f * 2]
                let r = stereoScratch[f * 2 + 1]
                out[f] = remover.process(left: l, right: r)
            }
            // Zero any tail beyond what we produced.
            if want < n { for f in want..<n { out[f] = 0 } }
            return noErr
        }
        self.sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()

        // The scratch lives for the lifetime of the closure; deallocate on stop.
        self.deallocScratch = { stereoScratch.deallocate() }
    }

    private var deallocScratch: (() -> Void)?

    func stop() {
        engine.stop()
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        deallocScratch?()
        deallocScratch = nil
    }
}
