"""
02_quantize.py -- Post-Training Quantization + Weight Export
=============================================================
Loads float checkpoint, calibrates per-layer scales and right-shifts
on 2000 MNIST images, then exports INT8 weights + INT32 biases to hex.

Output layout (weights/):
  c1_weight.hex   INT8  [6, 1, 5, 5]   = 150 values, 1 byte each
  c1_bias.hex     INT32 [6]             = 6 values,   4 bytes each
  c3_weight.hex   INT8  [16, 6, 5, 5]  = 2400 values
  c3_bias.hex     INT32 [16]
  c5_weight.hex   INT8  [120, 16, 5, 5]= 48000 values
  c5_bias.hex     INT32 [120]
  f6_weight.hex   INT8  [84, 120]       = 10080 values
  f6_bias.hex     INT32 [84]
  out_weight.hex  INT8  [10, 84]        = 840 values
  out_bias.hex    INT32 [10]
  right_shifts.json   {"c1":N,"c3":N,"c5":N,"f6":N,"out":N}
  scales.json         full scale chain for reference

Hex format (Verilog $readmemh compatible):
  INT8  -> 2 hex chars per line (two's complement, e.g. FF=-1, 7F=127)
  INT32 -> 8 hex chars per line (big-endian two's complement)

Run: python 02_quantize.py
"""

import json
import math
import numpy as np
import torch
from torch.utils.data import DataLoader, Subset
import torchvision
import torchvision.transforms as T
from pathlib import Path

# Import model definition from 01_train.py
from train_golden_model import LeNet5        # rename 01_train.py -> train_01.py first
# OR copy the LeNet5 class here directly (paste below if needed)

# ==============================================================================
# CONFIG
# ==============================================================================
CKPT_PATH    = Path("checkpoint/lenet5_float.pt")
OUT_DIR      = Path("weights")
CALIB_SIZE   = 2000       # images for calibration
HEADROOM_BITS = 1         # target = 127 >> 1 = 63  (50% headroom for safety)
DEVICE       = torch.device("cpu")   # calibration always on CPU for reproducibility

# ==============================================================================
# SCALE HELPERS
# ==============================================================================
def w_scale(tensor: np.ndarray) -> float:
    """Symmetric INT8 weight scale: max|w| / 127."""
    return max(float(np.abs(tensor).max()) / 127.0, 1e-8)


def compute_rs(int_peak: float, headroom_bits: int = HEADROOM_BITS) -> int:
    """
    Minimum rs such that (int_peak >> rs) <= (127 >> headroom_bits).
    headroom_bits=1 -> target=63 -> 50% of INT8 used -> 2x buffer for drift.
    """
    target = 127 >> headroom_bits   # = 63
    if int_peak <= target:
        return 0
    return math.ceil(math.log2(float(int_peak) / target))


# ==============================================================================
# CALIBRATION: measure actual activation peaks via forward hooks
# ==============================================================================
@torch.no_grad()
def calibrate(model: LeNet5, calib_loader: DataLoader) -> dict:
    """
    Run calib_loader through float model.
    Return per-layer peak float activation (before ReLU, after conv/fc).
    """
    model.eval()
    peaks = {"c1": 0.0, "c3": 0.0, "c5": 0.0, "f6": 0.0, "out": 0.0}

    def hook(name):
        def fn(_, _input, output):
            p = float(output.detach().abs().max())
            if p > peaks[name]:
                peaks[name] = p
        return fn

    handles = [
        model.c1.register_forward_hook(hook("c1")),
        model.c3.register_forward_hook(hook("c3")),
        model.c5.register_forward_hook(hook("c5")),
        model.f6.register_forward_hook(hook("f6")),
        model.out.register_forward_hook(hook("out")),
    ]

    print(f"  Calibrating on {CALIB_SIZE} images...")
    for x, _ in calib_loader:
        model(x)
    for h in handles:
        h.remove()

    print(f"  Float peaks: { {k: f'{v:.4f}' for k, v in peaks.items()} }")
    return peaks


# ==============================================================================
# COMPUTE SCALES AND RIGHT-SHIFTS
# ==============================================================================
def compute_scales(params: dict, peaks: dict) -> tuple[dict, dict, dict]:
    """
    Returns:
      scales      -- float scales for each weight tensor
      acc_scales  -- float scale of each accumulator (for bias conversion)
      right_shifts-- int rs for each layer
    """
    s = {}   # weight scales
    for name in ["c1", "c3", "c5", "f6", "out"]:
        s[name] = w_scale(params[f"{name}.weight"])

    # Scale chain
    s_pixel  = 1.0 / 255.0
    s_c1_acc = s_pixel  * s["c1"]
    rs_c1    = compute_rs(peaks["c1"] / s_c1_acc)
    s_c1_out = s_c1_acc * (1 << rs_c1)

    s_c3_acc = s_c1_out * s["c3"]
    rs_c3    = compute_rs(peaks["c3"] / s_c3_acc)
    s_c3_out = s_c3_acc * (1 << rs_c3)

    s_c5_acc = s_c3_out * s["c5"]
    rs_c5    = compute_rs(peaks["c5"] / s_c5_acc)
    s_c5_out = s_c5_acc * (1 << rs_c5)

    s_f6_acc = s_c5_out * s["f6"]
    rs_f6    = compute_rs(peaks["f6"] / s_f6_acc)
    s_f6_out = s_f6_acc * (1 << rs_f6)

    s_out_acc = s_f6_out * s["out"]
    rs_out    = compute_rs(peaks["out"] / s_out_acc)

    acc_scales = {
        "c1":  s_c1_acc,
        "c3":  s_c3_acc,
        "c5":  s_c5_acc,
        "f6":  s_f6_acc,
        "out": s_out_acc,
    }
    right_shifts = {"c1": rs_c1, "c3": rs_c3, "c5": rs_c5, "f6": rs_f6, "out": rs_out}

    print(f"\n  Right-shifts (data-driven, headroom_bits={HEADROOM_BITS}):")
    target = 127 >> HEADROOM_BITS
    peak_int_by_layer = {
        "c1":  peaks["c1"] / s_c1_acc,
        "c3":  peaks["c3"] / s_c3_acc,
        "c5":  peaks["c5"] / s_c5_acc,
        "f6":  peaks["f6"] / s_f6_acc,
        "out": peaks["out"] / s_out_acc,
    }
    for layer, rs in right_shifts.items():
        peak_int = peak_int_by_layer[layer]
        after    = int(peak_int) >> rs if rs > 0 else int(peak_int)
        print(f"    {layer.upper()}: peak_int={peak_int:>10,.0f}  rs={rs:>2}  "
              f"after_shift={after:>4}  target={target}  "
              f"headroom={127/max(after,1):.1f}x")

    return s, acc_scales, right_shifts


# ==============================================================================
# QUANTIZE TENSORS
# ==============================================================================
def quantize_weight(tensor: np.ndarray, scale: float) -> np.ndarray:
    """Float weight -> INT8 (symmetric, clipped to [-127, 127])."""
    q = np.round(tensor / scale).astype(np.int32)
    q = np.clip(q, -127, 127)
    return q.astype(np.int8)


def quantize_bias(tensor: np.ndarray, acc_scale: float) -> np.ndarray:
    """Float bias -> INT32. Bias is added BEFORE the right-shift."""
    q = np.round(tensor / acc_scale).astype(np.int64)
    q = np.clip(q, -(1 << 31), (1 << 31) - 1)
    return q.astype(np.int32)


# ==============================================================================
# HEX EXPORT
# ==============================================================================
def to_hex_int8(arr: np.ndarray) -> list[str]:
    """INT8 array -> list of 2-char hex strings (two's complement)."""
    return [f"{v:02X}" for v in arr.flatten().astype(np.int8).view(np.uint8)]


def to_hex_int32(arr: np.ndarray) -> list[str]:
    """INT32 array -> list of 8-char hex strings (big-endian two's complement)."""
    return [f"{v:08X}" for v in arr.flatten().astype(np.int32).view(np.uint32)]


def write_hex(lines: list[str], path: Path) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


# ==============================================================================
# MAIN
# ==============================================================================
def main():
    # ---- Load model ----
    model = LeNet5()
    model.load_state_dict(torch.load(CKPT_PATH, map_location="cpu"))
    model.eval()
    print(f"Loaded checkpoint: {CKPT_PATH}")

    # ---- Raw float params ----
    params = {k: v.numpy() for k, v in model.state_dict().items()}

    # ---- Calibration data ----
    tf = T.Compose([T.Pad(2), T.ToTensor()])
    ds = torchvision.datasets.MNIST("./data", train=True, download=True, transform=tf)
    subset = Subset(ds, list(range(CALIB_SIZE)))
    calib_ld = DataLoader(subset, batch_size=128, shuffle=False)

    print("\n[1/4] Calibrating activation peaks...")
    peaks = calibrate(model, calib_ld)

    print("\n[2/4] Computing scales and right-shifts...")
    scales, acc_scales, right_shifts = compute_scales(params, peaks)

    print("\n[3/4] Quantizing weights and biases...")
    quant = {
        "c1_weight":  quantize_weight(params["c1.weight"],  scales["c1"]),
        "c1_bias":    quantize_bias(  params["c1.bias"],    acc_scales["c1"]),
        "c3_weight":  quantize_weight(params["c3.weight"],  scales["c3"]),
        "c3_bias":    quantize_bias(  params["c3.bias"],    acc_scales["c3"]),
        "c5_weight":  quantize_weight(params["c5.weight"],  scales["c5"]),
        "c5_bias":    quantize_bias(  params["c5.bias"],    acc_scales["c5"]),
        "f6_weight":  quantize_weight(params["f6.weight"],  scales["f6"]),
        "f6_bias":    quantize_bias(  params["f6.bias"],    acc_scales["f6"]),
        "out_weight": quantize_weight(params["out.weight"], scales["out"]),
        "out_bias":   quantize_bias(  params["out.bias"],   acc_scales["out"]),
    }

    for name, arr in quant.items():
        print(f"  {name:<15}: shape={str(arr.shape):<20} "
              f"min={arr.min():>5}  max={arr.max():>5}  dtype={arr.dtype}")

    print("\n[4/4] Writing hex files...")
    OUT_DIR.mkdir(exist_ok=True)

    for name, arr in quant.items():
        path = OUT_DIR / f"{name}.hex"
        if "bias" in name:
            lines = to_hex_int32(arr)
        else:
            lines = to_hex_int8(arr)
        write_hex(lines, path)
        print(f"  {path}  ({len(lines)} values)")

    # Save metadata
    (OUT_DIR / "right_shifts.json").write_text(
        json.dumps(right_shifts, indent=2), encoding="ascii")

    scales_out = {
        "s_pixel":   1.0 / 255.0,
        "s_c1_acc":  acc_scales["c1"],
        "s_c3_acc":  acc_scales["c3"],
        "s_c5_acc":  acc_scales["c5"],
        "s_f6_acc":  acc_scales["f6"],
        "s_out_acc": acc_scales["out"],
    }
    (OUT_DIR / "scales.json").write_text(
        json.dumps({k: float(f"{v:.6e}") for k, v in scales_out.items()}, indent=2),
        encoding="ascii")

    print(f"\nDone. Output: {OUT_DIR.resolve()}")
    print(f"right_shifts.json: {right_shifts}")


if __name__ == "__main__":
    main()