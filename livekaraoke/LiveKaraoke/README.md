# LiveKaraoke — M0: System-Audio Capture Spike

A minimal SwiftUI macOS app that taps **all system audio** with the native
Core Audio process-tap API (macOS 14.4+), shows a live **level meter**, and can
optionally **pass the audio through to your output** so you can hear it.

This retires the riskiest unknown in the project (native system capture +
permissions) before we build DSP, autotune, or lyrics.

## Requirements
- macOS **14.4 or later** (the process-tap API)
- Xcode 15.4+
- Apple Silicon recommended

## Build & run
1. Open `LiveKaraoke.xcodeproj` in Xcode.
2. Select the **LiveKaraoke** scheme → **My Mac**.
3. In *Signing & Capabilities*, set your **Team** (automatic signing).
4. Run (⌘R).
5. Play any audio (Music, Spotify, a YouTube tab). Click **Start Capture** —
   the meter should move. Toggle **Monitor to output** (before Start) and use
   **headphones** to hear the tapped audio.

## What to expect on first launch
- macOS may prompt for audio/recording permission — allow it.
- If capture fails, the status line shows the failing Core Audio call + OSStatus.

## Files
| File | Role |
|------|------|
| `SystemAudioCapture.swift` | tap → aggregate device → IOProc; RMS level; ring feed |
| `RingBuffer.swift` | SPSC lock-free float ring (capture → monitor) |
| `AudioMonitor.swift` | AVAudioEngine passthrough to default output |
| `ContentView.swift` | UI: start/stop, meter, monitor toggle, status |
| `LiveKaraoke.entitlements` | dev: sandbox off, audio-input on |
| `Info.plist` | min OS 14.4, mic usage string |

## Known caveats (this is a spike)
- **Not compiled on CI** — written against Apple's "Capturing system audio with
  Core Audio taps" pattern. The CoreAudio tap/aggregate plumbing is fiddly; a
  small on-device fix may be needed on first build.
- App Sandbox is **off** for development. Re-enable + validate before any
  distribution.
- Passthrough is spike-grade (drops on overrun, no drift handling). It exists to
  prove audio flows, not as the final monitoring path.
- The level meter scales RMS up (×3) for visibility; not calibrated dBFS.

## M1 (implemented): vocal removal
The monitor path now runs **mid/side band-split cancellation** (`VocalRemover.swift`):
keeps centered lows (<120 Hz) and highs (>9 kHz), drops the centered vocal band,
keeps off-center instruments. Toggle **Remove vocals** live to A/B against the
full mix. Crude vs. neural separation (that's M4) but instant.

## M2 (implemented): autotune the singer
Mic is captured in the same engine; `PitchDetector.swift` (YIN) estimates the
singer's f0, `MusicScale.swift` snaps it to the nearest in-key note, and
`VoiceAutotune.swift` drives an `AVAudioUnitTimePitch` by the required cents.
UI adds a **Microphone** toggle, **Autotune** toggle, **Key/Scale** pickers, and
a **Retune** strength slider — all live. (TimePitch adds some latency; a tighter
PSOLA path is M5.)

Mic needs permission — allow the prompt on first Start with Microphone on.
**Headphones required** so the mic doesn't re-capture the backing track.

## M3 (implemented): synced lyrics
The captured system audio is streamed into **ShazamKit** (`SongIdentifier.swift`)
to identify the track; `LyricsProvider.swift` then fetches time-synced **LRC**
lyrics from lrclib.net, and `LyricsController` + `LyricsView` scroll them in time
(clock seeded by Shazam's match offset). Toggle **Show lyrics** before Start.

Needs **network access** (lyrics fetch) and the **ShazamKit capability**: in
Xcode ▸ target ▸ *Signing & Capabilities*, add **ShazamKit**. If a track has no
synced lyrics on lrclib, the panel says so.

## Permissions that persist across rebuilds
macOS ties permission grants (Microphone, audio capture) to the app's **bundle
id + signing identity**. If either changes per build you get re-prompted (or
silently denied). This project is set up so grants stick:
- Bundle id is fixed: `com.livekaraoke.LiveKaraoke`.
- `LiveKaraoke/Signing.xcconfig` centralizes signing — **set your `DEVELOPMENT_TEAM`
  there once** so every build uses the same Apple Development certificate (a free
  Apple ID works).
- Avoid "Sign to Run Locally" / ad-hoc signing — its identity changes every build,
  which is the usual cause of repeated prompts.

## M4 (implemented): neural separator option
A **Separation** picker chooses **Band-split (fast)** or **Neural (Core ML)**.
`NeuralSeparator.swift` loads a `VocalSeparator` Core ML model if one is bundled
and runs it on a worker thread, bridged to output via a mono ring (off the render
thread). Band-split stays inline and RT-safe. The model isn't shipped (large,
license-bound) — convert one with `tools/convert_separator_coreml.py`; until then
the Neural segment shows "(add model)" and band-split is used.

## M5 (implemented): polish
- **Auto-detect key** (`KeyDetector.swift`): chroma via Accelerate FFT correlated
  with Krumhansl–Schmuckler profiles; drives the autotune key/scale live. Toggle
  **Auto-detect key from track**.
- **Recording/export**: the **Record** button taps the final mix and writes an
  AAC `.m4a` to `~/Music`.
- **Presets** (`Presets.swift`): Off / Gentle / Natural / Hard, plus the last-used
  settings are persisted via `UserDefaults`.

(Sandboxed builds will need a user-selected save location or the Music-folder
entitlement; dev build writes to ~/Music directly.)

## Status
M0–M5 implemented. Remaining work is on-device validation and a real neural
separation model (`tools/`). The DSP/CoreAudio paths are written against Apple's
documented APIs but have not been compiled on CI — expect minor first-build
fixes.
