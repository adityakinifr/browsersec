//
//  LyricsController.swift
//  LiveKaraoke — M3
//
//  Owns lyric state: takes a Shazam match, fetches synced lyrics, runs a song
//  clock (seeded by the match offset), and publishes the current line index for
//  the scrolling lyrics view.
//

import Foundation
import Combine

@MainActor
final class LyricsController: ObservableObject {
    @Published private(set) var nowPlaying: String = ""
    @Published private(set) var status: String = "Lyrics off"
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var currentIndex: Int = -1

    private var matchOffset: TimeInterval = 0
    private var matchDate: Date = .now
    private var clock: Timer?
    private var fetchTask: Task<Void, Never>?

    /// Current estimated position in the song.
    private var songTime: TimeInterval {
        matchOffset + Date.now.timeIntervalSince(matchDate)
    }

    func handleMatch(title: String, artist: String, matchOffset: TimeInterval) {
        let label = artist.isEmpty ? title : "\(title) — \(artist)"
        // Same song already loaded: just re-seed the clock, keep lyrics.
        let isSame = (nowPlaying == label && !lines.isEmpty)
        nowPlaying = label
        self.matchOffset = matchOffset
        self.matchDate = .now

        if isSame { return }

        status = "Fetching lyrics…"
        lines = []
        currentIndex = -1
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            let result = await LyricsProvider.fetch(artist: artist, title: title)
            guard let self else { return }
            if let result, !result.isEmpty {
                self.lines = result
                self.status = "Synced lyrics loaded"
                self.startClock()
            } else {
                self.status = "No synced lyrics found"
            }
        }
    }

    func searching() {
        if lines.isEmpty { status = "Listening for a song…" }
    }

    func reset() {
        clock?.invalidate(); clock = nil
        fetchTask?.cancel(); fetchTask = nil
        nowPlaying = ""
        status = "Lyrics off"
        lines = []
        currentIndex = -1
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !lines.isEmpty else { return }
        let t = songTime
        // Last line whose timestamp has passed.
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.time <= t { idx = i } else { break }
        }
        if idx != currentIndex { currentIndex = idx }
    }
}
