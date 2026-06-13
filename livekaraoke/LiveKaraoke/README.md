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

## Next (M1)
Replace "straight passthrough" with **center-channel vocal cancellation**
(mid/side, band-split) so the monitor becomes an instrument-only karaoke track.
