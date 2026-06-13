//
//  ContentView.swift
//  LiveKaraoke — M0 capture spike UI
//

import SwiftUI

struct ContentView: View {
    @StateObject private var capture = SystemAudioCapture()

    var body: some View {
        VStack(spacing: 24) {
            Text("LiveKaraoke · M0")
                .font(.largeTitle.bold())
            Text("System-audio capture spike")
                .foregroundStyle(.secondary)

            LevelMeter(level: capture.level)
                .frame(height: 28)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button(capture.isRunning ? "Stop" : "Start Capture") {
                    capture.isRunning ? capture.stop() : capture.start()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)

                Toggle("Monitor to output", isOn: $capture.monitorEnabled)
                    .toggleStyle(.switch)
                    .disabled(capture.isRunning) // set before starting
            }

            Toggle("Remove vocals (karaoke)", isOn: $capture.removeVocals)
                .toggleStyle(.switch)
                .help("Mid/side band-split cancellation. Toggle live to A/B against the full mix.")

            Divider()

            // M2 — autotune the singer
            VStack(spacing: 12) {
                HStack {
                    Toggle("Microphone", isOn: $capture.micEnabled)
                        .toggleStyle(.switch)
                        .disabled(capture.isRunning) // set before starting
                    Spacer()
                    Toggle("Autotune", isOn: $capture.autotuneEnabled)
                        .toggleStyle(.switch)
                }

                HStack {
                    Picker("Key", selection: $capture.scaleRoot) {
                        ForEach(NoteName.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 120)

                    Picker("Scale", selection: $capture.scaleType) {
                        ForEach(ScaleType.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                HStack {
                    Text("Retune")
                    Slider(value: $capture.retuneStrength, in: 0...1)
                    Text(String(format: "%.0f%%", capture.retuneStrength * 100))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Text(capture.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text("Play any audio (Music, Spotify, a browser tab), then Start. "
                 + "The meter should move. Use headphones if you enable Monitor.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 440, minHeight: 520)
    }
}

/// A simple horizontal VU-style meter, 0...1.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}

#Preview {
    ContentView()
}
