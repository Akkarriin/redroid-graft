#!/usr/bin/env python3
"""Skip allocate-time gbm_bo_map in libgbm_mesa_wrapper.so (Intel xe crash).

Waydroid's gbm_mesa_alloc probes map_stride by import+map+unmap when
needs_map_stride is set (BO_USE_SW_MASK). On Arc/xe that path SIGSEGVs inside
Mesa dri_flush. SW buffers are already force_linear, so map_stride == stride.

Supported builds (file offset == VA for these LOADs unless noted):
  LOS20 x86_64: VA/file 0x409c
  LOS22 x86_64: VA/file 0x3076
  LOS22 i386:   VA 0x3674 / file 0x2674 (text LOAD bias 0x1000)
"""
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

# (file_off, orig, patch) — patch may be longer than orig (overwrites into skipped block)
VARIANTS: list[tuple[int, bytes, bytes]] = [
    # LOS20 x86_64: cmpb $0,0x16(%rbp); je skip
    # → mov 0x1c(%rbp),%eax; mov %eax,0x28(%rbp); jmp skip
    (
        0x409C,
        bytes.fromhex("807d16000f8450010000"),
        bytes.fromhex("8b451c894528e94f010000"),
    ),
    # LOS22 x86_64: cmpb $1,0x16(%r14); jne skip
    # → mov 0x1c(%r14),%eax; mov %eax,0x28(%r14); jmp skip
    (
        0x3076,
        bytes.fromhex("41807e16010f8550010000"),
        bytes.fromhex("418b461c41894628e94e010000"),
    ),
    # LOS22 i386: cmpb $1,0x12(%edi); jne skip  (10B)
    # → mov 0x18(%edi),%eax; mov %eax,0x24(%edi); jmp skip  (11B into skipped block)
    # after patch RIP=0x367f; skip@0x37d4 → rel 0x155
    (
        0x2674,
        bytes.fromhex("807f12010f8556010000"),
        bytes.fromhex("8b4718894724e955010000"),
    ),
]


def main() -> int:
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2] if len(sys.argv) > 2 else str(src))
    data = bytearray(src.read_bytes())

    for off, orig, patch in VARIANTS:
        end = off + max(len(orig), len(patch))
        if end > len(data):
            continue
        cur = bytes(data[off : off + len(orig)])
        already = bytes(data[off : off + len(patch)])
        if already == patch or (
            len(patch) > len(orig) and already[: len(orig)] == patch[: len(orig)]
        ):
            print(f"already patched (@{off:#x}): {src}")
            if dst != src:
                dst.write_bytes(data)
            return 0
        if cur == orig:
            data[off : off + len(patch)] = patch
            dst.write_bytes(data)
            print(f"patched @{off:#x} {src} -> {dst} md5={hashlib.md5(data).hexdigest()}")
            return 0

    print(f"no known signature in {src}", file=sys.stderr)
    for off, orig, _ in VARIANTS:
        if off + len(orig) <= len(data):
            got = bytes(data[off : off + len(orig)])
            print(f"  @{off:#x}: got {got.hex()} want {orig.hex()}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
