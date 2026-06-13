//
//  SystemAudioCapture.swift
//  LiveKaraoke
//
//  M0 spike: capture *all* system audio using the native Core Audio process-tap
//  API (macOS 14.4+), compute an RMS level for a meter, and feed mono samples
//  into a ring buffer for the optional passthrough monitor.
//
//  Flow:
//    1. CATapDescription(stereoGlobalTapButExcludeProcesses: [])  -> tap whole system
//    2. AudioHardwareCreateProcessTap(...)                        -> tapID
//    3. read tap format (kAudioTapPropertyFormat) + UID (kAudioTapPropertyUID)
//    4. AudioHardwareCreateAggregateDevice([...tap...])           -> aggregateID
//    5. AudioDeviceCreateIOProcIDWithBlock(...)                   -> IO callback
//    6. AudioDeviceStart(...)                                     -> samples flow
//
//  Modeled on Apple's "Capturing system audio with Core Audio taps" sample.
//  This is hardware-touching code that cannot be compiled on CI here; expect to
//  iterate slightly on first on-device build.
//

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

@MainActor
final class SystemAudioCapture: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var level: Float = 0      // 0...1 RMS, smoothed
    @Published var monitorEnabled = false
    @Published var removeVocals = true {
        didSet { monitor?.removeVocals = removeVocals }
    }

    // M2: microphone autotune
    @Published var micEnabled = false
    @Published var autotuneEnabled = true {
        didSet { monitor?.setAutotuneEnabled(autotuneEnabled) }
    }
    @Published var retuneStrength: Float = 1.0 {
        didSet { monitor?.setRetuneStrength(retuneStrength) }
    }
    @Published var scaleRoot: NoteName = .c {
        didSet { monitor?.updateScale(currentScale) }
    }
    @Published var scaleType: ScaleType = .chromatic {
        didSet { monitor?.updateScale(currentScale) }
    }

    private var currentScale: MusicScale {
        MusicScale(root: scaleRoot, type: scaleType)
    }

    // M3: lyrics
    @Published var lyricsEnabled = false
    let lyrics = LyricsController()

    @Published private(set) var status = "Idle"

    private var songIdentifier: SongIdentifier?
    private var lyricsActive = false   // plain Bool, read on the audio thread

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private var ring = FloatRingBuffer(capacity: 1 << 16)
    private var monitor: AudioMonitor?
    private var sampleRate: Double = 48_000

    // Written on the audio thread, read on a UI timer. Plain Float: aligned
    // word access is atomic on arm64, good enough for a meter.
    private var rawLevel: Float = 0
    private var levelTimer: Timer?

    // MARK: - Public control

    func start() {
        guard !isRunning else { return }
        // Mic needs TCC permission; request before building the input graph.
        if micEnabled {
            requestMicAccess { [weak self] granted in
                guard let self else { return }
                if granted { self.beginCapture() }
                else { self.status = "Microphone access denied" }
            }
        } else {
            beginCapture()
        }
    }

    private func beginCapture() {
        do {
            try setUpTap()
            try setUpAggregateDevice()
            try setUpIOProc()
            try AudioDeviceStartChecked()
            if monitorEnabled || micEnabled {
                let m = AudioMonitor(ring: ring,
                                     sampleRate: sampleRate,
                                     removeVocals: removeVocals,
                                     instrumentalEnabled: monitorEnabled,
                                     micEnabled: micEnabled,
                                     scale: currentScale,
                                     autotuneEnabled: autotuneEnabled,
                                     retuneStrength: retuneStrength)
                try m.start()
                monitor = m
            }
            if lyricsEnabled { setUpSongIdentifier() }
            startLevelTimer()
            isRunning = true
            status = statusLine()
        } catch {
            status = "Start failed: \(error.localizedDescription)"
            tearDown()
        }
    }

    private func statusLine() -> String {
        var parts = ["Capturing @ \(Int(sampleRate)) Hz"]
        if monitorEnabled { parts.append(removeVocals ? "instrumental" : "full mix") }
        if micEnabled { parts.append(autotuneEnabled ? "mic+autotune" : "mic") }
        return parts.joined(separator: " · ")
    }

    private func setUpSongIdentifier() {
        guard let id = SongIdentifier(sampleRate: sampleRate) else {
            lyrics.searching(); return
        }
        id.onMatch = { [weak self] match in
            self?.lyrics.handleMatch(title: match.title,
                                     artist: match.artist,
                                     matchOffset: match.matchOffset)
        }
        id.onStatus = { [weak self] _ in self?.lyrics.searching() }
        id.start()
        songIdentifier = id
        lyricsActive = true
    }

    private func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func stop() {
        guard isRunning else { return }
        tearDown()
        isRunning = false
        level = 0
        status = "Stopped"
    }

    // MARK: - Tap

    private func setUpTap() throws {
        // Tap every process' output, mixed to stereo, excluding none.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "LiveKaraoke System Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // don't mute the original playback

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateProcessTap(desc, &newTap)
        guard err == noErr else { throw caError("AudioHardwareCreateProcessTap", err) }
        tapID = newTap

        // Pull the tap's stream format so the aggregate + monitor agree on rate.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let fmtErr = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        if fmtErr == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }
    }

    private func tapUID() throws -> String {
        var cf: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let err = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw caError("kAudioTapPropertyUID", err) }
        return cf as String
    }

    // MARK: - Aggregate device

    private func setUpAggregateDevice() throws {
        let uid = try tapUID()
        let aggUID = "com.livekaraoke.aggregate.\(UUID().uuidString)"

        let tapList: [[String: Any]] = [[
            kAudioSubTapUIDKey as String: uid,
            kAudioSubTapDriftCompensationKey as String: true
        ]]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "LiveKaraoke Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapListKey as String: tapList,
            kAudioAggregateDeviceTapAutoStartKey as String: true
        ]

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg)
        guard err == noErr else { throw caError("AudioHardwareCreateAggregateDevice", err) }
        aggregateID = newAgg
    }

    // MARK: - IOProc

    private func setUpIOProc() throws {
        let queue = DispatchQueue(label: "com.livekaraoke.capture", qos: .userInteractive)

        let block: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            self.handle(inputData: inInputData)
        }

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, block)
        guard err == noErr, let procID else {
            throw caError("AudioDeviceCreateIOProcIDWithBlock", err)
        }
        ioProcID = procID
    }

    /// Runs on the capture queue (audio thread). Keep it allocation-light.
    /// Writes *interleaved stereo* [L,R,L,R,...] into the ring so downstream
    /// stages (M1 vocal removal) have both channels; computes a mono RMS meter.
    private nonisolated func handle(inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let first = abl.first,
              let p0 = first.mData?.assumingMemoryBound(to: Float.self) else {
            return
        }

        // Two common tap layouts:
        //  (a) non-interleaved: abl.count == 2, one buffer per channel
        //  (b) interleaved:     one buffer, mNumberChannels == 2
        let nonInterleaved = abl.count >= 2
        let frames: Int
        var leftAt: (Int) -> Float
        var rightAt: (Int) -> Float

        if nonInterleaved {
            let p1 = abl[1].mData?.assumingMemoryBound(to: Float.self) ?? p0
            frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            leftAt = { p0[$0] }
            rightAt = { p1[$0] }
        } else {
            let ch = Int(first.mNumberChannels == 0 ? 1 : first.mNumberChannels)
            frames = (Int(first.mDataByteSize) / MemoryLayout<Float>.size) / max(ch, 1)
            if ch >= 2 {
                leftAt = { p0[$0 * ch] }
                rightAt = { p0[$0 * ch + 1] }
            } else {
                leftAt = { p0[$0] }      // mono source: duplicate
                rightAt = { p0[$0] }
            }
        }
        guard frames > 0 else { return }

        var sumSquares: Float = 0
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames * 2)
        defer { scratch.deallocate() }
        let feedLyrics = lyricsActive
        let mono = feedLyrics
            ? UnsafeMutableBufferPointer<Float>.allocate(capacity: frames) : nil
        defer { mono?.deallocate() }

        for f in 0..<frames {
            let l = leftAt(f), r = rightAt(f)
            scratch[f * 2] = l
            scratch[f * 2 + 1] = r
            let m = (l + r) * 0.5
            sumSquares += m * m
            mono?[f] = m
        }

        let rms = (sumSquares / Float(frames)).squareRoot()
        self.rawLevel = rms   // single aligned Float write; fine for a meter

        if self.monitorEnabled {
            self.ring.write(UnsafeBufferPointer(scratch))
        }
        if let mono {
            songIdentifier?.appendMono(UnsafeBufferPointer(mono))
        }
    }

    // MARK: - Level metering (UI thread)

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Simple attack/decay smoothing for a nicer meter.
                let target = min(1, self.rawLevel * 3)   // scale up; system audio RMS is low
                let smoothing: Float = target > self.level ? 0.5 : 0.15
                self.level += (target - self.level) * smoothing
            }
        }
    }

    // MARK: - Start / teardown helpers

    private func AudioDeviceStartChecked() throws {
        let err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw caError("AudioDeviceStart", err) }
    }

    private func tearDown() {
        levelTimer?.invalidate(); levelTimer = nil
        monitor?.stop(); monitor = nil
        lyricsActive = false
        songIdentifier?.stop(); songIdentifier = nil
        lyrics.reset()

        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        rawLevel = 0
        // Fresh ring for the next run.
        ring = FloatRingBuffer(capacity: 1 << 16)
    }

    private func caError(_ what: String, _ status: OSStatus) -> NSError {
        NSError(domain: "CoreAudio", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(what) failed (OSStatus \(status))"])
    }
}
