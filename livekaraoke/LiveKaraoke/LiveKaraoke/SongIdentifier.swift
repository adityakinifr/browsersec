//
//  SongIdentifier.swift
//  LiveKaraoke — M3
//
//  Identifies the currently-playing song by streaming the *captured system
//  audio* into ShazamKit. We don't use the microphone for this (headphones mean
//  the room mic can't hear the track); instead the capture IOProc feeds mono
//  samples here, and a drain timer hands fixed chunks to SHSession.
//
//  Requires the ShazamKit capability/entitlement and network access.
//

import Foundation
import AVFoundation
import ShazamKit

final class SongIdentifier: NSObject, SHSessionDelegate {

    struct Match {
        let title: String
        let artist: String
        let matchOffset: TimeInterval   // position into the track at match time
    }

    /// Called on the main queue when a confident match arrives.
    var onMatch: ((Match) -> Void)?
    var onStatus: ((String) -> Void)?

    private let session = SHSession()
    private let format: AVAudioFormat
    private let ring: FloatRingBuffer
    private let pcmBuffer: AVAudioPCMBuffer
    private let chunkFrames: AVAudioFrameCount = 4096
    private let drainQueue = DispatchQueue(label: "com.livekaraoke.shazam")
    private var timer: DispatchSourceTimer?
    private var lastMatchTitle: String?

    init?(sampleRate: Double) {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else {
            return nil
        }
        self.format = fmt
        self.pcmBuffer = buf
        self.ring = FloatRingBuffer(capacity: 1 << 18)
        super.init()
        session.delegate = self
    }

    /// Producer side — called from the capture audio thread.
    func appendMono(_ samples: UnsafeBufferPointer<Float>) {
        ring.write(samples)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: drainQueue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
        onStatus?("Listening for a song…")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastMatchTitle = nil
    }

    private func drain() {
        guard ring.availableToRead >= Int(chunkFrames) else { return }
        guard let ch = pcmBuffer.floatChannelData else { return }
        let out = UnsafeMutableBufferPointer(start: ch[0], count: Int(chunkFrames))
        ring.read(into: out)
        pcmBuffer.frameLength = chunkFrames
        session.matchStreamingBuffer(pcmBuffer, at: nil)
    }

    // MARK: SHSessionDelegate
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        let title = item.title ?? "Unknown"
        let artist = item.artist ?? ""
        // Avoid spamming the same match repeatedly.
        if title == lastMatchTitle { return }
        lastMatchTitle = title
        let offset = item.matchOffset
        DispatchQueue.main.async { [weak self] in
            self?.onMatch?(Match(title: title, artist: artist, matchOffset: offset))
        }
    }

    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // Normal while no recognizable song is playing; stay quiet.
    }
}
