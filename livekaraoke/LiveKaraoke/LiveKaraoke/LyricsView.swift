//
//  LyricsView.swift
//  LiveKaraoke — M3
//
//  Scrolling, auto-centering synced-lyrics display. The current line is
//  highlighted and kept in view.
//

import SwiftUI

struct LyricsView: View {
    @ObservedObject var controller: LyricsController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "music.note")
                Text(controller.nowPlaying.isEmpty ? "—" : controller.nowPlaying)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(controller.lines.enumerated()), id: \.element.id) { i, line in
                            Text(line.text)
                                .font(i == controller.currentIndex ? .title3.bold() : .body)
                                .foregroundStyle(i == controller.currentIndex ? .primary : .secondary)
                                .id(i)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(height: 180)
                .onChange(of: controller.currentIndex) { _, idx in
                    guard idx >= 0 else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }
}
