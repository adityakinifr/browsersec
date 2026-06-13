# LiveKaraoke (macOS) — Design & Roadmap

A macOS app that captures whatever audio is playing, removes the lead vocals
in real time so you can sing over the instrumental, shows time-synced lyrics
on screen, and auto-tunes the singer's mic to the song's key.

**Confirmed scope**
- Source: **live system audio** (Spotify, Apple Music, YouTube, etc.)
- "Take out the lyrics" = **remove vocals** AND **show lyrics text**
- Auto-tune the live mic input
- Deliverable for now: **this plan** (no app code yet)

---

## 1. The governing constraint: latency

A singer monitoring their own voice tolerates only **~20–30 ms** of round-trip
latency before it feels "off" and throws them off pitch. Every design decision
below is in service of that budget.

The painful tension:
- **High-quality vocal removal** (neural source separation — Demucs/MDX/Spleeter)
  needs lookahead and runs at **150–500 ms** latency. Great for a pre-rendered
  backing track, unusable inside a live monitoring loop.
- **Low-latency vocal removal** (center-channel cancellation, sub-5 ms) is crude
  but instant.

Resolution: **the backing track and the voice are two separate latency domains.**
- The *backing track* the singer hears can tolerate more latency (they're
  following it, not generating it) — but it must stay in sync with the lyrics.
- The *voice* must be near-instant, so autotune runs on a tight, dedicated path.

We do NOT need the singer's voice to pass through the vocal-removal stage, which
is what makes the budget achievable.

```
                       ┌──────────────────────────┐
 System audio  ─────▶  │  Vocal Removal (backing)  │ ─┐
 (process tap)         └──────────────────────────┘  │
                                                      ├─▶ Mixer ─▶ Output
 Microphone ─▶ Pitch detect ─▶ Autotune (tight loop) ─┘            (headphones)
                                                      ▲
                       Lyrics overlay (synced to backing-track clock)
```

---

## 2. Subsystems

### 2.1 System-audio capture  — difficulty: LOW/MED ✅
- **macOS 14.4+**: Core Audio process-tap API
  (`AudioHardwareCreateProcessTap` + aggregate device) — tap a specific app's
  output (or the whole system) with no third-party virtual driver.
- **Fallback (macOS 13+)**: ScreenCaptureKit audio capture.
- **Legacy fallback**: instruct user to install BlackHole (virtual device).
- Output: a float PCM stream into our `AVAudioEngine` graph.
- Risks: TCC permission prompts (Screen Recording / audio capture entitlement);
  some DRM streams; sample-rate matching.

### 2.2 Vocal removal (backing track)  — difficulty: HIGH ⚠️
Tiered, ship the cheap one first:

1. **Center-channel cancellation (MVP).** Vocals are usually panned center, so
   `mid = (L+R)/2`, `side = (L−R)/2`; emphasize `side` to suppress vocals.
   Sub-5 ms, pure vDSP. Weaknesses: dents centered bass/kick, fails on mono or
   heavily-reverbed/wide vocals, leaves artifacts. Add a band-split so we only
   cancel the vocal frequency range (~150 Hz–8 kHz) and keep low-end punch.
2. **Light real-time neural separator (v2).** A small causal/streaming model
   (e.g. a tiny Demucs/TF-Lite-class net) via **Core ML on the Neural Engine**,
   block-processed at ~20–40 ms blocks. Better quality, added latency — fine for
   the backing path, kept out of the voice path.
3. **Offline high-quality (v3, only for "Local files" mode later).** Full Demucs
   render → perfect instrumental. Not applicable to live source.

### 2.3 Auto-tune the singer  — difficulty: MED 🎚️
- **Pitch detection**: YIN / pYIN or autocorrelation on short frames (~5–10 ms).
- **Correction**: snap detected f0 to nearest note in the song's scale, then
  pitch-shift via **PSOLA** (low latency, good for monophonic voice) or a phase
  vocoder. Expose a "retune speed"/strength knob (hard T-Pain vs. gentle).
- **Needs the key/scale.** Sources, in priority order:
  1. User picks key/scale in the UI (always available, zero-latency).
  2. Derive from the matched lyrics/song metadata if we have a song DB.
  3. Live key estimation from the backing track (chroma analysis) — nice-to-have.
- Tight path target: detect + shift + output under ~15 ms.

### 2.4 Lyrics — identify + sync + display  — difficulty: MED 📝
- **Don't transcribe live** (streaming ASR lags and mis-hears). Instead:
  1. **Identify the song**: read "Now Playing" via the `MediaRemote`/now-playing
     APIs, or audio-fingerprint (Shazam's **ShazamKit** `SHSession` does this
     on-device and natively!).
  2. **Fetch time-synced lyrics** (LRC format) from a lyrics provider keyed on
     the identified track.
  3. **Display & scroll** synced to the backing-track playback clock; bouncing-
     ball / current-line highlight.
- Fallback when no LRC exists: streaming Whisper (Core ML) for a rough,
  delayed caption — clearly marked as best-effort.
- Risk: lyrics-provider licensing/ToS; ShazamKit needs entitlement.

---

## 3. Tech stack
- **Language/UI**: Swift + SwiftUI (lyrics overlay, controls), AppKit where needed.
- **Audio graph**: AVAudioEngine; custom `AVAudioUnit`/render-callback nodes for
  the DSP stages. Real-time-safe code (no locks/allocs on the audio thread).
- **DSP**: Accelerate / **vDSP** (FFT, mid-side, filters), PSOLA hand-rolled.
- **ML**: Core ML + Metal/Neural Engine for the neural separator and optional ASR.
- **Song ID**: ShazamKit; now-playing via MediaRemote.
- **Lyrics**: LRC parser + provider client.
- **Packaging**: Xcode project, hardened runtime, the relevant entitlements
  (audio capture, microphone, ShazamKit).

---

## 4. Latency budget (target, monitoring loop)
| Stage (voice path)        | Target |
|---------------------------|--------|
| Mic input buffer          | 5–10 ms |
| Pitch detect + PSOLA      | 5–8 ms |
| Mix + output buffer       | 5–10 ms |
| **Voice round-trip**      | **~20–28 ms** |

Backing-track path may run looser (separation + buffering, tens–hundreds ms);
it is delay-compensated against the lyrics clock, not against the singer.

---

## 5. Milestone roadmap
- **M0 — Capture spike.** Process-tap system audio → straight to output. Prove
  permissions + sample-rate plumbing. (Smallest risky unknown, do first.)
- **M1 — Vocal removal v1.** Mid/side center-channel cancel with band-split;
  A/B toggle. Now it's a usable instrument-only monitor.
- **M2 — Autotune.** Mic capture → YIN → PSOLA snap to a user-set key; mix into
  output with the backing track. This is the first "karaoke" moment.
- **M3 — Lyrics.** ShazamKit song ID → LRC fetch → synced scrolling overlay.
- **M4 — Neural separation.** Core ML streaming separator as a quality toggle.
- **M5 — Polish.** Key auto-detect, latency calibration UI, recording/export,
  presets.

**Recommended build order rationale:** M0 and M1 retire the two biggest
technical unknowns (native system capture, real-time separation quality) before
investing in autotune/lyrics, which are well-trodden.

---

## 6. Open risks / things to validate early
1. **Process-tap entitlement & TCC** — confirm we can ship it (notarization).
2. **Center-cancel quality** on real tracks — may be too crude; sets urgency of M4.
3. **Lyrics licensing** — provider ToS for redistribution/display.
4. **DRM** — some protected streams may not be tappable.
5. **End-to-end singer latency** on target hardware — measure on M-series early.

---

## 7. Non-goals (for now)
- Windows/Linux, mobile.
- Multi-singer / networked duets.
- Studio mastering of recordings.
