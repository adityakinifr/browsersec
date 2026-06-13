# LiveKaraoke

A macOS karaoke app that, from **whatever audio is currently playing** on your
Mac, removes the lead vocals in real time so you can sing over the instrumental,
shows **time-synced lyrics** on screen, and **auto-tunes** the singer's mic to
the song's key.

> Status: **design phase.** No app code yet — see [`docs/DESIGN.md`](docs/DESIGN.md)
> for the full architecture, latency budget, and milestone roadmap.

## What it does (target)
- 🎧 **Capture live system audio** via the native macOS process-tap API (14.4+).
- 🎚️ **Remove vocals** in real time (center-channel cancellation → streaming
  neural separator).
- 🎤 **Auto-tune** the live mic with low-latency pitch correction (YIN + PSOLA).
- 📝 **Show synced lyrics** by identifying the song (ShazamKit) and fetching LRC.

## The hard part
A singer can't tolerate more than ~20–30 ms of monitoring latency. The design
keeps the voice path tight by routing the singer's mic **around** the (slower)
vocal-removal stage. Details in the design doc.

## Roadmap (build order retires risk first)
- **M0** — native system-audio capture spike
- **M1** — center-channel vocal removal
- **M2** — mic autotune (user-set key)
- **M3** — synced lyrics (ShazamKit + LRC)
- **M4** — streaming neural separator (quality toggle)
- **M5** — polish (key auto-detect, latency calibration, recording)

## Stack
Swift / SwiftUI · AVAudioEngine · Accelerate (vDSP) · Core ML · ShazamKit

## License
TBD.
