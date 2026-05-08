#!/usr/bin/env python3
"""
Convert the Demucs htdemucs model to CoreML for the iOS app.

Requirements:
    pip install torch demucs coremltools

Usage:
    python convert_to_coreml.py

Output:
    Demucs.mlpackage   (copy this into Xcode project under StemMixer/)

The iOS app expects:
  - Input:  "audio"  shape [1, 2, 352800]  float32  (1 batch, stereo, 8 s @ 44100 Hz)
  - Output: "stems"  shape [1, 4, 2, 352800] float32 (4 stems: drums/bass/vocals/other)
"""

import torch
import torch.nn as nn
import numpy as np

SEGMENT_SAMPLES = 352800   # 8 seconds @ 44100 Hz
STEM_ORDER = ["drums", "bass", "vocals", "other"]


class DemucsSegmentWrapper(nn.Module):
    """Wraps a single htdemucs forward pass on a fixed-size segment."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, audio: torch.Tensor) -> torch.Tensor:
        # audio: [1, 2, SEGMENT_SAMPLES]
        with torch.no_grad():
            stems = self.model(audio)  # [1, 4, 2, SEGMENT_SAMPLES]
        return stems


def main():
    print("Loading htdemucs model from demucs package…")
    try:
        from demucs.pretrained import get_model
    except ImportError:
        print("ERROR: demucs not installed. Run:  pip install demucs")
        return

    model = get_model("htdemucs")
    model.eval()

    print(f"  sample_rate = {model.samplerate}")
    print(f"  sources     = {model.sources}")
    print(f"  STEM_ORDER  = {STEM_ORDER}")

    # Verify stem order matches expected
    if list(model.sources) != STEM_ORDER:
        print(f"WARNING: model.sources {model.sources} != expected {STEM_ORDER}")
        print("         Update STEM_ORDER in StemSeparationService.swift to match.")

    wrapper = DemucsSegmentWrapper(model)
    wrapper.eval()

    dummy = torch.zeros(1, 2, SEGMENT_SAMPLES)

    print("Tracing model… (this may take a minute)")
    try:
        traced = torch.jit.trace(wrapper, dummy)
        traced = torch.jit.optimize_for_inference(traced)
    except Exception as e:
        print(f"torch.jit.trace failed: {e}")
        print("Trying torch.jit.script fallback…")
        traced = torch.jit.script(wrapper)

    print("Converting to CoreML…")
    try:
        import coremltools as ct
    except ImportError:
        print("ERROR: coremltools not installed. Run:  pip install coremltools")
        return

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio",
                              shape=(1, 2, SEGMENT_SAMPLES),
                              dtype=np.float32)],
        outputs=[ct.TensorType(name="stems")],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )

    # Add metadata
    mlmodel.short_description = "Demucs htdemucs stem separator"
    mlmodel.input_description["audio"]  = "Stereo audio segment [1, 2, 352800] at 44100 Hz"
    mlmodel.output_description["stems"] = "4 stems [1, 4, 2, 352800]: drums, bass, vocals, other"

    out_path = "Demucs.mlpackage"
    mlmodel.save(out_path)
    print(f"\nSaved: {out_path}")
    print("\nNext steps:")
    print("  1. Open your Xcode project")
    print("  2. Drag Demucs.mlpackage into the StemMixer target")
    print("  3. Make sure 'Copy items if needed' is checked")
    print("  4. Build & run")


if __name__ == "__main__":
    main()
