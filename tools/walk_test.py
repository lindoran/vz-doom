#!/usr/bin/env python3
"""
walk_test.py — M3 verification: run walk.bin in the Z80 simulator with
scripted keyboard input, checking movement physics and that every rendered
frame is byte-exact against the Python reference cast at the player's state.

Keyboard rows are memory-mapped reads in the sim too — we just poke the row
bytes ($6800-$6FFF default $FF = no keys) before each frame.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z80sim import Z80, load_syms
import gen_tables as g

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOAD = 0x7AE9

KROW0, KROW1, KROW4 = 0x68FE, 0x68FD, 0x68EF
# hardware-verified bit order (reversed vs common docs)
W, S, A, D = (KROW0, 0x02), (KROW1, 0x02), (KROW1, 0x10), (KROW1, 0x08)
COMMA, DOT = (KROW4, 0x08), (KROW4, 0x02)

def load_walk_syms():
    syms = {}
    for line in open(os.path.join(ROOT, "build", "walk.sym")):
        parts = line.replace(":", "").split()
        if len(parts) >= 3 and parts[1] == "EQU":
            syms[parts[0]] = int(parts[2], 16)
    return syms

SYMS = load_walk_syms()

def run(frames, keys=(), key_from=0):
    """Run N complete frames; hold `keys` from frame index key_from onward.
    Returns (cpu, list of (frame_idx, px, py, pang) at each frame boundary)."""
    mem = bytearray(65536)
    code = open(os.path.join(ROOT, "build", "walk.bin"), "rb").read()
    mem[LOAD:LOAD + len(code)] = code
    for addr in range(0x6800, 0x7000):
        mem[addr] = 0xFF                       # no keys pressed

    cpu = Z80(mem)
    cpu.pc = LOAD
    main_addr = SYMS["MAIN"]

    hits = 0
    while cpu.icount < 100_000_000:
        if cpu.pc == main_addr:
            if hits >= frames:
                break
            # apply keyboard state for the frame about to run
            for addr in (KROW0, KROW1, KROW4):
                mem[addr] = 0xFF
            if hits >= key_from:
                for addr, mask in keys:
                    mem[addr] &= ~mask & 0xFF
            hits += 1
        cpu.step()
    else:
        raise SystemExit("instruction limit hit")

    return cpu, mem

def state(mem):
    px = mem[SYMS["PXV"]] | (mem[SYMS["PXV"] + 1] << 8)
    py = mem[SYMS["PYV"]] | (mem[SYMS["PYV"] + 1] << 8)
    pang = mem[SYMS["PANGV"]]
    return px, py, pang

def check_render(mem, label):
    px, py, pang = state(mem)
    ref = g.cast_frame(px, py, pang)
    vram = bytes(mem[0x7000:0x7800])
    diffs = sum(1 for i in range(2048) if vram[i] != ref[i])
    ok = diffs == 0
    print(f"  {label}: pos=({px/256:.3f},{py/256:.3f}) ang={pang} "
          f"render {'MATCH' if ok else f'{diffs} DIFFS'}")
    return ok

passed = True

# 1. Idle: nothing pressed, 2 frames — must equal M2 scene, state unchanged
cpu, mem = run(2)
px, py, pang = state(mem)
assert (px, py, pang) == (0x0780, 0x0280, 64), f"idle state moved! {state(mem)}"
passed &= check_render(mem, "idle 2f          ")

# 2. Walk forward 20 frames: stepY(64)=32/frame, stepX=0
cpu, mem = run(20, keys=[W])
px, py, pang = state(mem)
exp_py = 0x0280 + 20 * 32
assert (px, py) == (0x0780, exp_py), f"walk pos wrong: {px:04X},{py:04X} exp py={exp_py:04X}"
passed &= check_render(mem, "W x20            ")

# 3. Walk into the wall at y=9 (x=7 corridor): must stop at 0x08E0 and stay
cpu, mem = run(80, keys=[W])
px, py, pang = state(mem)
assert py == 0x08E0, f"collision stop wrong: py={py:04X} expected 08E0"
assert px == 0x0780, f"px drifted: {px:04X}"
passed &= check_render(mem, "W x80 (wall stop)")

# 4. Turn left 10 frames: PANG = 64 + 10*2
cpu, mem = run(10, keys=[A])
px, py, pang = state(mem)
assert pang == 84, f"turn wrong: {pang}"
assert (px, py) == (0x0780, 0x0280), "turning moved the player!"
passed &= check_render(mem, "A x10            ")

# 5. Strafe left 8 frames: angle 64+64=128 -> stepX=-32, stepY=0
cpu, mem = run(8, keys=[COMMA])
px, py, pang = state(mem)
exp_px = 0x0780 - 8 * 32
assert (px, py, pang) == (exp_px, 0x0280, 64), f"strafe wrong: {px:04X},{py:04X},{pang}"
passed &= check_render(mem, ", x8             ")

# 6. Combined: turn right 32 frames (angle 0 = +X) then walk 16 frames
cpu, mem = run(48, keys=[D], key_from=0)
# re-run scripted: 32 frames D, then release and hold W — do it manually
mem2 = None
def run_script(script, total):
    mem = bytearray(65536)
    code = open(os.path.join(ROOT, "build", "walk.bin"), "rb").read()
    mem[LOAD:LOAD + len(code)] = code
    for addr in range(0x6800, 0x7000):
        mem[addr] = 0xFF
    cpu = Z80(mem)
    cpu.pc = LOAD
    main_addr = SYMS["MAIN"]
    hits = 0
    while cpu.icount < 200_000_000:
        if cpu.pc == main_addr:
            if hits >= total:
                break
            for addr in (KROW0, KROW1, KROW4):
                mem[addr] = 0xFF
            for frm_range, keys in script:
                if frm_range[0] <= hits < frm_range[1]:
                    for addr, mask in keys:
                        mem[addr] &= ~mask & 0xFF
            hits += 1
        cpu.step()
    return mem

mem = run_script([((0, 32), [D]), ((32, 48), [W])], 48)
px, py, pang = state(mem)
assert pang == (64 - 32 * 2) & 0xFF, f"turn-then-walk angle: {pang}"       # 0 = +X
exp_px = 0x0780 + 16 * 32                                                  # walked +X
assert (px, py) == (exp_px, 0x0280), f"turn-then-walk pos: {px:04X},{py:04X}"
passed &= check_render(mem, "D x32 then W x16 ")

print()
print("ALL PASS" if passed else "FAILURES — see above")
sys.exit(0 if passed else 1)
