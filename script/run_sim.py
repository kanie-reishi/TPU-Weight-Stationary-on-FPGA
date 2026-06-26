#!/usr/bin/env python3
"""Trinh chay simulation Verilog/SystemVerilog cho du an TPU LeNet-5.

Cong cu nay duoc thiet ke de chay on dinh tren may cai iverilog qua
oss-cad-suite, ke ca khi duoc goi boi AI agent (Gemini, Cursor, ...).

No tu dong:
  1. Activate moi truong oss-cad-suite (tranh loi vvp crash do thieu DLL/config).
  2. Gom toan bo nguon RTL (rtl/**/*.sv, ke ca legacy) + file testbench.
  3. Tu do ten module top trong file testbench (ten module != ten file).
  4. Bien dich bang `iverilog -g2012` (bat buoc cho SystemVerilog).
  5. Chay `vvp` o dung thu muc du lieu de `$readmemh(...)` tim duoc file hex.

Vi du:
    python script/run_sim.py tb_conv1
    python script/run_sim.py tb_tpu_top
    python script/run_sim.py tb/tb_lenet5_full.sv --workdir tb
    python script/run_sim.py tb_lenet5_nodma --rtl-dir rtlNoDma --workdir tb
    python script/run_sim.py tb_conv1 --oss "D:/Downloads/oss-cad-suite"
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TB_DIR = ROOT / "tb"
BUILD_DIR = ROOT / "build"

DEFAULT_OSS = r"D:\Downloads\oss-cad-suite"

MODULE_RE = re.compile(r"^\s*module\s+(\w+)", re.MULTILINE)


def resolve_testbench(arg: str) -> Path:
    """Tim file testbench tu ten hoac duong dan."""
    candidate = Path(arg)
    if candidate.is_file():
        return candidate.resolve()

    if not candidate.is_absolute():
        rel = (ROOT / arg).resolve()
        if rel.is_file():
            return rel

    name = candidate.stem if candidate.suffix else candidate.name
    for ext in (".sv", ".v"):
        guess = TB_DIR / f"{name}{ext}"
        if guess.is_file():
            return guess.resolve()

    sys.exit(f"[ERROR] Khong tim thay testbench: {arg!r} (da thu {TB_DIR})")


def detect_top_module(tb_file: Path) -> str:
    """Doc ten module dau tien trong file testbench."""
    text = tb_file.read_text(encoding="utf-8", errors="ignore")
    match = MODULE_RE.search(text)
    if not match:
        sys.exit(f"[ERROR] Khong doc duoc ten module top trong {tb_file}")
    return match.group(1)


def collect_sources(tb_file: Path, rtl_dir: Path) -> list[Path]:
    """Gom tat ca RTL + testbench. Module rtl/ va rtl/legacy/ khong trung ten."""
    sources = sorted(rtl_dir.rglob("*.sv")) + sorted(rtl_dir.rglob("*.v"))
    if tb_file not in sources:
        sources.append(tb_file)
    return sources


def find_oss(oss_arg: str | None) -> Path | None:
    """Xac dinh thu muc oss-cad-suite (de activate environment.bat)."""
    candidates = [oss_arg, os.environ.get("OSS_CAD_SUITE"), DEFAULT_OSS]
    for c in candidates:
        if c and (Path(c) / "environment.bat").is_file():
            return Path(c)
    return None


def build_prefix(oss: Path | None) -> str:
    """Tien to lenh de activate moi truong (chay trong cung 1 process cmd)."""
    if os.name == "nt" and oss is not None:
        return f'call "{oss / "environment.bat"}" && '
    return ""


def run_cmd(cmd: str) -> int:
    """Chay chuoi lenh qua cmd.exe (Windows) hoac shell (khac).

    Dung shell=True de cmd.exe nhan nguyen chuoi, tranh viec subprocess
    escape lai dau nhay (loi `is not recognized ...`).
    """
    print(f"\n>>> {cmd}\n", flush=True)
    proc = subprocess.run(cmd, shell=True)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Chay simulation iverilog/vvp cho du an TPU LeNet-5.",
    )
    parser.add_argument("testbench", help="Ten hoac duong dan testbench, vd tb_conv1")
    parser.add_argument("--top", help="Ten module top (mac dinh: tu do trong file tb)")
    parser.add_argument(
        "--workdir",
        help="Thu muc chay vvp (mac dinh: thu muc chua testbench, thuong la tb/)",
    )
    parser.add_argument("--oss", help="Duong dan oss-cad-suite (mac dinh: env OSS_CAD_SUITE)")
    parser.add_argument(
        "--rtl-dir",
        default="rtl",
        help="Thu muc RTL (mac dinh: rtl; dung rtlNoDma cho stream path)",
    )
    parser.add_argument(
        "--define",
        dest="defines",
        action="append",
        default=[],
        help="Them +define+NAME hoac +define+NAME=VAL (co the lap lai)",
    )
    parser.add_argument("--vcd", action="store_true", help="Bao TB dump waveform (define DUMP_WAVE)")
    args = parser.parse_args()

    tb_file = resolve_testbench(args.testbench)
    top = args.top or detect_top_module(tb_file)
    workdir = Path(args.workdir).resolve() if args.workdir else tb_file.parent
    rtl_dir = (ROOT / args.rtl_dir).resolve()
    if not rtl_dir.is_dir():
        sys.exit(f"[ERROR] Khong tim thay thu muc RTL: {rtl_dir}")
    oss = find_oss(args.oss)

    if os.name == "nt" and oss is None:
        print(
            "[WARN] Khong tim thay oss-cad-suite (environment.bat). "
            "vvp co the crash. Dat bien OSS_CAD_SUITE hoac dung --oss.",
            file=sys.stderr,
        )

    BUILD_DIR.mkdir(exist_ok=True)
    out_vvp = BUILD_DIR / f"{tb_file.stem}.vvp"

    sources = collect_sources(tb_file, rtl_dir)
    src_args = " ".join(f'"{p}"' for p in sources)
    define = "-DDUMP_WAVE " if args.vcd else ""
    for d in args.defines:
        define += f"-D{d} "

    prefix = build_prefix(oss)

    print("=" * 70)
    print(f" Testbench : {tb_file}")
    print(f" Top module: {top}")
    print(f" RTL dir   : {rtl_dir}")
    print(f" Workdir   : {workdir}")
    print(f" Output    : {out_vvp}")
    print(f" Sources   : {len(sources)} file")
    print(f" OSS suite : {oss if oss else '(khong activate)'}")
    print("=" * 70)

    compile_cmd = (
        f'{prefix}iverilog -g2012 {define}-o "{out_vvp}" -s {top} {src_args}'
    )
    rc = run_cmd(compile_cmd)
    if rc != 0:
        print(f"\n[FAIL] Bien dich loi (exit {rc}).", file=sys.stderr)
        return rc

    run_simulation = f'{prefix}cd /d "{workdir}" && vvp "{out_vvp}"'
    if os.name != "nt":
        run_simulation = f'{prefix}cd "{workdir}" && vvp "{out_vvp}"'
    rc = run_cmd(run_simulation)
    if rc != 0:
        print(f"\n[FAIL] vvp loi (exit {rc}).", file=sys.stderr)
        return rc

    print("\n[DONE] Simulation ket thuc (exit 0).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
