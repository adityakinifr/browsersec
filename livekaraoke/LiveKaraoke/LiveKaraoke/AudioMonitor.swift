//
//  AudioMonitor.swift
//  LiveKaraoke
//
//  Optional passthrough: pulls captured mono samples from the ring buffer and
//  plays them to the default output device via AVAudioEngine. Used so you can
//  *hear* the tapped system audio (proof the capture path carries real audio),
//  not just see a level meter. Beware feedback if you monitor through speakers
//  while also capturing system audio — use headphones.
//

import AVFoundation

final class AudioMonitor {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: FloatRingBuffer
    private let sampleRate: Double

    init(ring: FloatRingBuffer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
    }

    func start() throws {
        // Mono float source at the tap's sample rate; the engine will upmix /
        // sample-rate-convert to the output device as needed.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1) else {
            throw NSError(domain: "LiveKaraoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad monitor format"])
        }

        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buf = abl.first,
                  let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let out = UnsafeMutableBufferPointer(start: ptr, count: Int(frameCount))
            ring.read(into: out)
            return noErr
        }
        self.sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
        }
        sourceNode = nil
    }
}
