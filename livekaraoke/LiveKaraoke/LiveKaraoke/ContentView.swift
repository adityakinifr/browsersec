//
//  ContentView.swift
//  LiveKaraoke — Spotify-themed UI + real-time spectrum meter
//

import SwiftUI

// MARK: - Theme

enum Theme {
    static let green       = Color(red: 0.114, green: 0.725, blue: 0.329) // #1DB954
    static let greenBright = Color(red: 0.118, green: 0.843, blue: 0.376) // #1ED760
    static let bg          = Color(red: 0.073, green: 0.073, blue: 0.073) // #121212
    static let card        = Color(white: 0.11)
    static let cardHi      = Color(white: 0.16)
    static let textPrimary = Color.white
    static let textSecond  = Color(white: 0.66)

    /// Spotify-style top-tinted gradient backdrop.
    static var backdrop: LinearGradient {
        LinearGradient(colors: [Color(red: 0.10, green: 0.18, blue: 0.13), bg, bg],
                       startPoint: .top, endPoint: .bottom)
    }
}

private extension View {
    /// Rounded, slightly elevated card surface.
    func card(_ padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var capture = SystemAudioCapture()
    @StateObject private var nowPlaying = NowPlaying()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HeaderView()
                NowPlayingCard(nowPlaying: nowPlaying)
                SpectrumView(bands: capture.spectrum, active: capture.isRunning)
                    .frame(height: 150)
                    .card(14)
                TransportBar(capture: capture)
                KaraokeCard(capture: capture)
                VoiceCard(capture: capture)
                LyricsSection(capture: capture)
                StatusFooter(capture: capture)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.backdrop.ignoresSafeArea())
        .frame(minWidth: 480, minHeight: 860)
        .tint(Theme.green)
        .preferredColorScheme(.dark)
        .onAppear {
            // Drive synced lyrics off Spotify's exact track + playback position
            // (replaces ShazamKit fingerprinting, which the Shazam catalog gates
            // behind an entitlement). Re-seeds every poll for tight sync.
            nowPlaying.onUpdate = { [weak capture] title, artist, position, _ in
                guard let capture, capture.lyricsEnabled, !title.isEmpty else { return }
                capture.lyrics.handleMatch(title: title, artist: artist, matchOffset: position)
            }
            nowPlaying.start()
        }
        .onDisappear { nowPlaying.stop() }
    }
}

// MARK: - Header

private struct HeaderView: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.green).frame(width: 40, height: 40)
                Image(systemName: "music.mic")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.black)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LiveKaraoke")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text("Real-time vocal removal · autotune · lyrics")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Now playing (Spotify artwork + track)

private struct NowPlayingCard: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.cardHi)
                if let art = nowPlaying.artwork {
                    Image(nsImage: art)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(nowPlaying.title.isEmpty ? "Nothing playing" : nowPlaying.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(nowPlaying.artist.isEmpty ? "Play a track in Spotify" : nowPlaying.artist)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecond)
                    .lineLimit(1)
            }
            Spacer()
            if nowPlaying.playing && !nowPlaying.title.isEmpty {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Theme.green)
            }
        }
        .card(12)
    }
}

// MARK: - Spectrum meter (sharp Canvas bars + peak-hold caps)

struct SpectrumView: View {
    let bands: [Float]
    let active: Bool
    @State private var peaks: [CGFloat] = []

    var body: some View {
        Canvas { ctx, size in
            let n = bands.count
            guard n > 0 else { return }
            let gap: CGFloat = 2
            let bw = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 0..<n {
                let v = CGFloat(min(1, max(0, bands[i])))
                let x = CGFloat(i) * (bw + gap)
                let h = max(2, v * size.height)
                let top = size.height - h
                let colors = barColors(i, n)
                ctx.fill(Path(CGRect(x: x, y: top, width: bw, height: h)),
                         with: .linearGradient(Gradient(colors: colors),
                                               startPoint: CGPoint(x: 0, y: top),
                                               endPoint: CGPoint(x: 0, y: size.height)))
                // Crisp bright top edge.
                ctx.fill(Path(CGRect(x: x, y: top, width: bw, height: 1.5)),
                         with: .color(.white.opacity(0.9)))
                // Peak-hold cap.
                if i < peaks.count {
                    let py = size.height - max(2, peaks[i] * size.height)
                    ctx.fill(Path(CGRect(x: x, y: py, width: bw, height: 2)),
                             with: .color(Theme.greenBright))
                }
            }
        }
        .drawingGroup()
        .opacity(active ? 1 : 0.35)
        .onChange(of: bands) { _, nv in
            if peaks.count != nv.count {
                peaks = nv.map { CGFloat($0) }
            } else {
                for i in 0..<nv.count {
                    peaks[i] = Swift.max(CGFloat(nv[i]), peaks[i] - 0.012)
                }
            }
        }
    }

    /// Low→high frequency colour shift: Spotify green at the bass, teal/cyan up top.
    private func barColors(_ i: Int, _ n: Int) -> [Color] {
        let f = Double(i) / Double(max(1, n - 1))
        let hue = 0.39 + 0.10 * f
        return [Color(hue: hue, saturation: 0.80, brightness: 1.0),
                Color(hue: hue, saturation: 0.95, brightness: 0.5)]
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var capture: SystemAudioCapture

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { capture.isRunning ? capture.stop() : capture.start() }) {
                ZStack {
                    Circle().fill(Theme.green).frame(width: 58, height: 58)
                        .shadow(color: Theme.green.opacity(0.5), radius: 10)
                    Image(systemName: capture.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Play karaoke mix", isOn: $capture.monitorEnabled)
                    .disabled(capture.isRunning)
                Text(capture.isRunning
                     ? "Capturing"
                     : "Plays the processed audio · set before Start · use headphones")
                    .font(.caption).foregroundStyle(Theme.textSecond)
            }
            Spacer()

            Button(action: { capture.toggleRecording() }) {
                Label(capture.isRecording ? "Stop" : "Record",
                      systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(capture.isRecording ? Color.red.opacity(0.9) : Theme.cardHi)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!capture.isRunning)
            .opacity(capture.isRunning ? 1 : 0.5)
        }
        .toggleStyle(.switch)
        .card(16)
    }
}

// MARK: - Karaoke (vocal removal)

private struct KaraokeCard: View {
    @ObservedObject var capture: SystemAudioCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Karaoke", systemImage: "waveform")

            Toggle("Remove vocals", isOn: $capture.removeVocals)
                .toggleStyle(.switch)
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Removal strength").font(.caption).foregroundStyle(Theme.textSecond)
                    Spacer()
                    Text("\(Int(capture.removalStrength * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecond)
                }
                Slider(value: $capture.removalStrength, in: 0...1.5)
            }
            .disabled(!capture.removeVocals)
            .opacity(capture.removeVocals ? 1 : 0.5)

            Picker("Separation", selection: $capture.separationMethod) {
                ForEach(SeparationMethod.allCases) { m in
                    Text(m == .neural && !capture.neuralModelAvailable ? "Neural (add model)" : m.rawValue)
                        .tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(capture.isRunning)
        }
        .card()
    }
}

// MARK: - Voice (mic + autotune)

private struct VoiceCard: View {
    @ObservedObject var capture: SystemAudioCapture
    @State private var showAdvanced = false

    private var presetSelection: Binding<String?> {
        Binding(
            get: {
                AutotunePreset.all.first {
                    $0.autotuneEnabled == capture.autotuneEnabled
                        && abs($0.retuneStrength - capture.retuneStrength) < 0.001
                }?.name
            },
            set: { name in
                if let name, let p = AutotunePreset.all.first(where: { $0.name == name }) {
                    capture.apply(p)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Sing along", systemImage: "mic.fill")

            HStack {
                Toggle("Use my microphone", isOn: $capture.micEnabled).disabled(capture.isRunning)
                Spacer()
                Toggle("Autotune", isOn: $capture.autotuneEnabled)
            }
            .toggleStyle(.switch)
            .font(.system(size: 15, weight: .semibold))

            // Friendly autotune amount instead of raw "presets".
            VStack(alignment: .leading, spacing: 6) {
                Text("Autotune amount").font(.caption).foregroundStyle(Theme.textSecond)
                Picker("", selection: presetSelection) {
                    ForEach(AutotunePreset.all) { Text($0.name).tag(Optional($0.name)) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(!capture.autotuneEnabled)
            }
            .opacity(capture.autotuneEnabled ? 1 : 0.5)

            Toggle("Match the song's key automatically", isOn: $capture.autoDetectKey)
                .toggleStyle(.switch)
                .disabled(capture.isRunning)
                .font(.system(size: 13))

            // Music-theory controls only matter when not auto-matching; tuck them away.
            if !capture.autoDetectKey {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Picker("Key", selection: $capture.scaleRoot) {
                                ForEach(NoteName.allCases) { Text($0.label).tag($0) }
                            }
                            Picker("Scale", selection: $capture.scaleType) {
                                ForEach(ScaleType.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Retune strength").font(.caption).foregroundStyle(Theme.textSecond)
                                Spacer()
                                Text("\(Int(capture.retuneStrength * 100))%")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecond)
                            }
                            Slider(value: $capture.retuneStrength, in: 0...1)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
                .tint(Theme.textSecond)
            }
        }
        .card()
    }
}

// MARK: - Lyrics

private struct LyricsSection: View {
    @ObservedObject var capture: SystemAudioCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle("Lyrics", systemImage: "text.quote")
                Spacer()
                Toggle("", isOn: $capture.lyricsEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            if capture.lyricsEnabled {
                LyricsView(controller: capture.lyrics)
            }
        }
        .card()
    }
}

// MARK: - Status footer

private struct StatusFooter: View {
    @ObservedObject var capture: SystemAudioCapture

    var body: some View {
        VStack(spacing: 6) {
            Text(capture.status)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Play any audio, set Monitor on, then Start. Headphones recommended.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecond)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}

// MARK: - Bits

private struct SectionTitle: View {
    let text: String
    let systemImage: String
    init(_ text: String, systemImage: String) { self.text = text; self.systemImage = systemImage }
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
    }
}

#Preview {
    ContentView()
}
