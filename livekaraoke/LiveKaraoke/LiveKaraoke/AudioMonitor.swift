//
//  AudioMonitor.swift
//  LiveKaraoke
//
//  The output engine. Two sources mixed to the default output:
//   • Instrumental: captured system audio pulled from the ring buffer, run
//     through the M1 vocal remover (mono).
//   • Voice: the live microphone, pitch-corrected by the M2 autotune chain.
//
//  Use headphones — monitoring through speakers while capturing system audio
//  causes feedback, and the mic would re-capture the backing track.
//

import AVFoundation

final class AudioMonitor {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: FloatRingBuffer
    private let sampleRate: Double
    private let remover: VocalRemover

    private let voice = VoiceAutotune()
    private let instrumentalEnabled: Bool
    private let micEnabled: Bool

    private var deallocScratch: (() -> Void)?

    var removeVocals: Bool {
        get { remover.enabled }
        set { remover.enabled = newValue }
    }

    init(ring: FloatRingBuffer,
         sampleRate: Double,
         removeVocals: Bool,
         instrumentalEnabled: Bool,
         micEnabled: Bool,
         scale: MusicScale,
         autotuneEnabled: Bool,
         retuneStrength: Float) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.remover = VocalRemover(sampleRate: sampleRate)
        self.remover.enabled = removeVocals
        self.instrumentalEnabled = instrumentalEnabled
        self.micEnabled = micEnabled
        self.voice.scale = scale
        self.voice.enabled = autotuneEnabled
        self.voice.strength = retuneStrength
    }

    // MARK: live updates from the UI
    func updateScale(_ scale: MusicScale) { voice.scale = scale }
    func setAutotuneEnabled(_ on: Bool) { voice.enabled = on }
    func setRetuneStrength(_ s: Float) { voice.strength = s }

    func start() throws {
        if instrumentalEnabled { try attachInstrumental() }
        if micEnabled { try voice.attach(to: engine) }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if micEnabled { voice.detach() }
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        deallocScratch?()
        deallocScratch = nil
    }

    // MARK: instrumental source (ring -> vocal remover -> mono out)
    private func attachInstrumental() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1) else {
            throw NSError(domain: "LiveKaraoke", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad monitor format"])
        }

        let ring = self.ring
        let remover = self.remover
        let maxFrames = 4096
        let stereoScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxFrames * 2)
        stereoScratch.initialize(repeating: 0)
        self.deallocScratch = { stereoScratch.deallocate() }

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
                out[f] = remover.process(left: stereoScratch[f * 2],
                                         right: stereoScratch[f * 2 + 1])
            }
            if want < n { for f in want..<n { out[f] = 0 } }
            return noErr
        }
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
}
