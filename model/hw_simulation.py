"""
03_hw_sim.py -- Hardware Integer Simulation (Golden Reference)
===============================================================
Simulates the EXACT integer arithmetic performed by the Verilog RTL.
Use this as ground truth to verify each Vivado waveform signal.

MATCH POINTS with Verilog:
  hw_conv()           <-> conv_pe_array MAC accumulation
  hw_relu_shift_clamp <-> shift_relu_clamp.v  (ReLU + round-shift + clamp)
  hw_pool()           <-> pool_unit.v
  hw_fc()             <-> fc_pe_array MAC + bias

USAGE:
  python 03_hw_sim.py                 # evaluate accuracy on 500 test images
  python 03_hw_sim.py --diag          # print layer-by-layer values for 1 image
  python 03_hw_sim.py --pixel1        # use all-ones input (matches Verilog TC4)
  python 03_hw_sim.py --n 10000       # run on full test set

Run after 01_train.py and 02_quantize.py.
"""

import sys
import json
import argparse
import numpy as np
from pathlib import Path

try:
    from scipy.signal import correlate2d
except ImportError:
    print("[ERROR] scipy not found. Run: pip install scipy")
    sys.exit(1)

# ==============================================================================
# CONFIG
# ==============================================================================
WEIGHT_DIR = Path("weights")
DATA_DIR   = Path("data")

# ==============================================================================
# 1. LOAD WEIGHTS
# ==============================================================================
def load_hex_int8(name: str) -> np.ndarray:
    lines = (WEIGHT_DIR / f"{name}.hex").read_text().strip().splitlines()
    vals  = [int(h, 16) for h in lines if h.strip()]
    return np.array(vals, dtype=np.uint8).view(np.int8)


def load_hex_int32(name: str) -> np.ndarray:
    lines = (WEIGHT_DIR / f"{name}.hex").read_text().strip().splitlines()
    vals  = []
    for h in lines:
        h = h.strip()
        if not h:
            continue
        v = int(h, 16)
        # two's complement 32-bit
        if v >= 0x80000000:
            v -= 0x100000000
        vals.append(v)
    return np.array(vals, dtype=np.int32)


def load_weights() -> dict:
    print(f"[LOAD] {WEIGHT_DIR}/")
    w = {
        "c1_w":  load_hex_int8("c1_weight").reshape(6,   1,  5, 5),
        "c1_b":  load_hex_int32("c1_bias"),
        "c3_w":  load_hex_int8("c3_weight").reshape(16,  6,  5, 5),
        "c3_b":  load_hex_int32("c3_bias"),
        "c5_w":  load_hex_int8("c5_weight").reshape(120, 16, 5, 5),
        "c5_b":  load_hex_int32("c5_bias"),
        "f6_w":  load_hex_int8("f6_weight").reshape(84, 120),
        "f6_b":  load_hex_int32("f6_bias"),
        "out_w": load_hex_int8("out_weight").reshape(10, 84),
        "out_b": load_hex_int32("out_bias"),
    }
    for k, v in w.items():
        print(f"  {k:<8}: shape={str(v.shape):<20} min={v.min():>6}  max={v.max():>6}")
    with open(WEIGHT_DIR / "right_shifts.json") as f:
        rs = json.load(f)
    print(f"  right_shifts: {rs}")
    return w, rs


# ==============================================================================
# 2. INTEGER HARDWARE OPS
# Each function matches the corresponding Verilog module exactly.
# ==============================================================================

def hw_conv(x_uint8: np.ndarray,
            w_int8: np.ndarray,
            b_int32: np.ndarray) -> np.ndarray:
    """
    Integer 2D convolution -- matches conv_pe_array.v
      x_uint8 : [in_ch, H, W]  uint8  (pixel values from fmap bank)
      w_int8  : [out_ch, in_ch, kH, kW]  int8
      b_int32 : [out_ch]  int32  (pre-loaded into PE accumulator)
    Returns int64 accumulator [out_ch, H_out, W_out]  (before ReLU/shift)

    Accumulation order matches Verilog:
      acc = bias
      for each input position: acc += pixel * weight   (MAC)

    NOTE: uses int64 internally to avoid overflow during accumulation.
    The int32 hardware register is safe because:
      C3 max: 150 * 127 * 127 = 2,419,350 << 2^31
    """
    out_ch, in_ch, kH, kW = w_int8.shape
    H_out = x_uint8.shape[1] - kH + 1
    W_out = x_uint8.shape[2] - kW + 1
    acc   = np.zeros((out_ch, H_out, W_out), dtype=np.int64)

    for oc in range(out_ch):
        acc[oc] = int(b_int32[oc])    # pre-load bias (matches IDLE state in FC PE)
        for ic in range(in_ch):
            acc[oc] += correlate2d(
                x_uint8[ic].astype(np.int64),
                w_int8[oc, ic].astype(np.int64),
                mode="valid"
            )
    return acc   # int64 accumulator, no overflow risk


def hw_relu_shift_clamp(acc: np.ndarray, rs: int) -> np.ndarray:
    """ReLU + round-shift + clamp [0,127] — hidden layers (relu_en=1 on HW)."""
    return hw_shift_sat_int8(acc, rs, relu_en=True).astype(np.uint8)


def hw_shift_sat_int8(acc: np.ndarray, rs: int, relu_en: bool = False) -> np.ndarray:
    """
    Matches ofm_post_processor.sv stage 2–3:
      sum + rounding >>> rs, then signed saturate [-128,127], optional ReLU.
    """
    temp = acc.astype(np.int64)
    if rs == 0:
        shifted = temp
    else:
        rounding = np.int64(1) << (rs - 1)
        shifted = (temp + rounding) >> rs
    clamped = np.clip(shifted, -128, 127)
    if relu_en:
        clamped = np.maximum(clamped, 0)
    return clamped.astype(np.int8)


def hw_pool(x: np.ndarray, k: int = 2) -> np.ndarray:
    """
    Max pooling stride=k -- matches pool_unit.v
      x : [ch, H, W] uint8
    Returns [ch, H//k, W//k] uint8
    """
    ch, H, W = x.shape
    H_out, W_out = H // k, W // k
    out = np.zeros((ch, H_out, W_out), dtype=np.uint8)
    for i in range(H_out):
        for j in range(W_out):
            out[:, i, j] = x[:, i*k:i*k+k, j*k:j*k+k].max(axis=(1, 2))
    return out


def hw_fc(x_uint8: np.ndarray,
          w_int8: np.ndarray,
          b_int32: np.ndarray) -> np.ndarray:
    """
    Integer FC layer -- matches fc_pe_array.v
      x_uint8 : [in]  uint8
      w_int8  : [out, in]  int8
      b_int32 : [out]  int32
    Returns int64 accumulator [out]

    Accumulation: acc = bias + sum(x[k] * w[n][k] for k in range(in))
    Matches F6 FSM: IDLE loads bias, COMPUTE does MAC, FINISH applies ReLU+shift.
    """
    acc = b_int32.astype(np.int64) + (w_int8.astype(np.int64)
                                       @ x_uint8.astype(np.int64))
    return acc


# ==============================================================================
# 3. FULL FORWARD PASS
# ==============================================================================
def hw_forward(img_uint8: np.ndarray,
               weights: dict,
               rs: dict,
               verbose: bool = False) -> tuple[int, dict]:
    """
    Run one 32x32 uint8 image through the full hardware pipeline.
    Returns (predicted_class, intermediates_dict).

    img_uint8: [1, 32, 32] uint8
    """
    mid = {}   # intermediates for waveform comparison

    x = img_uint8    # [1, 32, 32]

    # ---- C1 ----
    c1_acc = hw_conv(x, weights["c1_w"], weights["c1_b"])          # [6, 28, 28]
    c1_out = hw_relu_shift_clamp(c1_acc, rs["c1"])                 # [6, 28, 28] uint8
    s2_out = hw_pool(c1_out)                                       # [6, 14, 14] uint8
    mid.update({"c1_acc": c1_acc, "c1_out": c1_out, "s2_out": s2_out})

    # ---- C3 ----
    c3_acc = hw_conv(s2_out, weights["c3_w"], weights["c3_b"])     # [16, 10, 10]
    c3_out = hw_relu_shift_clamp(c3_acc, rs["c3"])                 # [16, 10, 10] uint8
    s4_out = hw_pool(c3_out)                                       # [16, 5, 5] uint8
    mid.update({"c3_acc": c3_acc, "c3_out": c3_out, "s4_out": s4_out})

    # ---- C5 ----
    c5_acc = hw_conv(s4_out, weights["c5_w"], weights["c5_b"])     # [120, 1, 1]
    c5_acc = c5_acc[:, 0, 0]                                       # [120]
    c5_out = hw_relu_shift_clamp(c5_acc, rs["c5"])                 # [120] uint8
    mid.update({"c5_acc": c5_acc, "c5_out": c5_out})

    # ---- F6 ----
    f6_acc = hw_fc(c5_out, weights["f6_w"], weights["f6_b"])       # [84]
    f6_out = hw_relu_shift_clamp(f6_acc, rs["f6"])                 # [84] uint8
    mid.update({"f6_acc": f6_acc, "f6_out": f6_out})

    # ---- OUT: signed shift + saturate (relu_en=0 on HW) ----
    out_acc = hw_fc(f6_out, weights["out_w"], weights["out_b"])     # [10] int64
    logits  = hw_shift_sat_int8(out_acc, rs["out"], relu_en=False)  # [10] int8
    mid.update({"out_acc": out_acc, "logits": logits})

    pred = int(np.argmax(logits))

    if verbose:
        print(f"\n  C1_ACC  ch0(0,0)={c1_acc[0,0,0]:>8}  "
              f"min={c1_acc.min():>8}  max={c1_acc.max():>8}  "
              f"SAT@{127<<rs['c1']}")
        print(f"  C1_OUT  ch0(0,0)={c1_out[0,0,0]:>8}  "
              f"nonzero={np.count_nonzero(c1_out)}/{c1_out.size}")
        print(f"  S2_OUT  ch0(0,0)={s2_out[0,0,0]:>8}  "
              f"shape={s2_out.shape}")
        print(f"  C3_ACC  ch0(0,0)={c3_acc[0,0,0]:>8}  "
              f"min={c3_acc.min():>8}  max={c3_acc.max():>8}  "
              f"SAT@{127<<rs['c3']}")
        print(f"  C3_OUT  ch0(0,0)={c3_out[0,0,0]:>8}  "
              f"nonzero={np.count_nonzero(c3_out)}/{c3_out.size}")
        print(f"  S4_OUT  shape={s4_out.shape}  "
              f"ch0={s4_out[0].flatten().tolist()}")
        print(f"  C5_ACC  [0..7]={c5_acc[:8].tolist()}")
        print(f"  C5_OUT  [0..7]={c5_out[:8].tolist()}  "
              f"nonzero={np.count_nonzero(c5_out)}/120")
        print(f"  F6_ACC  [0..7]={f6_acc[:8].tolist()}")
        print(f"  F6_OUT  [0..7]={f6_out[:8].tolist()}  "
              f"nonzero={np.count_nonzero(f6_out)}/84")
        print(f"  OUT_ACC [0..9]={out_acc.tolist()}")
        print(f"  LOGITS  {logits.tolist()}  (rs={rs['out']})")
        print(f"  PRED    class={pred}  logit={int(logits[pred])}")

    return pred, mid


# ==============================================================================
# 4. ACCURACY EVALUATION
# ==============================================================================
def evaluate(weights: dict, rs: dict, n: int) -> float:
    try:
        import torchvision
        import torchvision.transforms as T
        ds = torchvision.datasets.MNIST(
            "./data", train=False, download=True,
            transform=T.Compose([T.Pad(2), T.ToTensor()])
        )
    except ImportError:
        print("[ERROR] torchvision required: pip install torchvision")
        return -1.0

    print(f"\n[EVAL] Running {n} test images...")
    correct = 0
    errors  = []

    for idx, (img, label) in enumerate(ds):
        if idx >= n:
            break
        img_uint8 = (img.numpy() * 255).round().astype(np.uint8)  # [1,32,32]
        pred, _   = hw_forward(img_uint8, weights, rs)
        if pred == label:
            correct += 1
        elif len(errors) < 5:
            errors.append((idx, int(label), pred))

        if (idx + 1) % 200 == 0:
            print(f"  [{idx+1:>5}/{n}]  running acc = {correct/(idx+1)*100:.2f}%")

    acc = correct / n * 100
    print(f"\n  ACCURACY: {correct}/{n} = {acc:.2f}%")
    if errors:
        print(f"  First errors (idx, true, pred): {errors}")
    return acc


# ==============================================================================
# 5. DIAGNOSTIC: pixel=1 constant image (matches Verilog testbench TC4)
# ==============================================================================
def run_diagnostic(weights: dict, rs: dict, pixel_val: int = 1):
    print(f"\n{'='*60}")
    print(f"  DIAGNOSTIC  pixel={pixel_val} (all pixels, 32x32)")
    print(f"  Compare each value with Vivado waveform at valid_out")
    print(f"{'='*60}")

    img = np.full((1, 32, 32), pixel_val, dtype=np.uint8)
    hw_forward(img, weights, rs, verbose=True)

    print(f"\n  Paste these into WAVEFORM_SAMPLES in Vivado testbench")
    print(f"  to verify hardware matches this golden reference.")


# ==============================================================================
# MAIN
# ==============================================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--diag",   action="store_true",
                        help="Print layer-by-layer values for pixel=1 image")
    parser.add_argument("--pixel1", action="store_true",
                        help="Same as --diag (alias)")
    parser.add_argument("--pixel",  type=int, default=1,
                        help="Pixel value for diagnostic (default 1)")
    parser.add_argument("--n",      type=int, default=500,
                        help="Number of test images for accuracy evaluation")
    args = parser.parse_args()

    weights, rs = load_weights()

    if args.diag or args.pixel1:
        run_diagnostic(weights, rs, pixel_val=args.pixel)
    else:
        acc = evaluate(weights, rs, args.n)
        print(f"\n  Target: >= 98.50%")
        if acc < 90:
            print("  STATUS: FAIL -- check weight loading or RS values")
            print("  HINT:   run --diag and compare with Vivado waveform")
        elif acc < 98.5:
            print("  STATUS: PARTIAL -- run --diag to find diverging layer")
        else:
            print("  STATUS: PASS")