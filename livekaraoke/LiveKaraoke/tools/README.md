# tools — neural separator model

LiveKaraoke's **Neural** vocal-removal tier (M4) loads a Core ML model named
`VocalSeparator` from the app bundle. The model is **not** committed here (large,
license-bound), so the app falls back to band-split until you add one.

## Model contract
| | name | dtype | shape |
|---|------|-------|-------|
| input  | `audioIn`       | Float32 | `[1, 2, BLOCK]` (channels-first L,R) |
| output | `accompaniment` | Float32 | `[1, 2, BLOCK]` |

`BLOCK` must equal `NeuralSeparator.blockSize` (default **1024**).

## Make the model
```bash
pip install torch coremltools
python convert_separator_coreml.py --block 1024 --out VocalSeparator.mlpackage
```
Edit `build_model()` in the script to wrap a real streaming separator (e.g. a
causal Demucs / Conv-TasNet that outputs the accompaniment stem). The stub ships
as an identity passthrough so you can validate the app wiring first.

## Install it
1. Drag `VocalSeparator.mlpackage` into the **LiveKaraoke** target in Xcode
   (check *Copy items if needed* and add to the target).
2. Build & run. The **Neural** segment in the Separation picker enables
   automatically (the app probes for the model at launch).

## Latency note
Neural separation runs on a worker thread and is bridged to the output through a
ring buffer, so it never blocks the audio render thread. It still adds ~one block
of latency (≈21 ms at 48 kHz for BLOCK=1024) — fine for the backing track, which
is why neural lives on the backing path and never in the singer's mic loop.
