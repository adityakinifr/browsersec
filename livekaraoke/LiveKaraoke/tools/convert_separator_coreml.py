#!/usr/bin/env python3
"""
convert_separator_coreml.py — produce VocalSeparator.mlpackage for LiveKaraoke.

LiveKaraoke's NeuralSeparator expects a Core ML model with this contract:

    input  "audioIn"        : Float32  MLMultiArray  shape [1, 2, BLOCK]  (L,R)
    output "accompaniment"  : Float32  MLMultiArray  shape [1, 2, BLOCK]

BLOCK must equal NeuralSeparator.blockSize (default 1024).

This script wraps any PyTorch source-separation model that maps a stereo block
to a stereo accompaniment block. Plug in your model below (e.g. a causal/
streaming Demucs/Conv-TasNet variant) and run:

    pip install torch coremltools
    python convert_separator_coreml.py --block 1024 --out VocalSeparator.mlpackage

Then drag VocalSeparator.mlpackage into the LiveKaraoke target (check "Copy
items if needed" and add to target) and pick "Neural" in the app.

NOTE: the actual separation weights are NOT included here — they are large and
license-bound. Supply your own model in `build_model()`.
"""

import argparse


def build_model(block: int):
    import torch
    import torch.nn as nn

    class StereoAccompaniment(nn.Module):
        """
        Replace this stub with a real streaming separator that returns the
        accompaniment (music minus vocals). The identity stub below lets the
        pipeline compile end-to-end so you can validate the app wiring before
        dropping in trained weights.
        """
        def forward(self, x):  # x: [1, 2, block]
            # TODO: return separator(x)["accompaniment"]
            return x

    model = StereoAccompaniment().eval()
    example = torch.zeros(1, 2, block)
    return torch.jit.trace(model, example), example


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--block", type=int, default=1024,
                    help="frames per inference; must match NeuralSeparator.blockSize")
    ap.add_argument("--out", default="VocalSeparator.mlpackage")
    args = ap.parse_args()

    import coremltools as ct

    traced, example = build_model(args.block)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audioIn", shape=example.shape)],
        outputs=[ct.TensorType(name="accompaniment")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "LiveKaraoke stereo accompaniment separator"
    mlmodel.save(args.out)
    print(f"Saved {args.out} (block={args.block}). Add it to the LiveKaraoke target.")


if __name__ == "__main__":
    main()
