#!/usr/bin/env python3
"""
kiosk_test.py — regression + new-behaviour verification for vzdoom_kiosk.asm.

This is doom_test.py's scenario set retargeted at the kiosk build, plus one
new scenario for the kiosk-specific respawn behaviour. It exists to answer
one question: did adding continuous-play / exhibit mode / the title screen
change anything about the underlying engine (movement, walls, doors, demon
AI, hitscan, damage, rendering)? Everything below except the last section
is unmodified in *intent* from doom_test.py — same assertions, same
reference data, just pointed at vzdoom_kiosk.bin/.sym.

Two scenarios from doom_test.py are intentionally NOT ported as-is, because
they test behaviour this file deliberately changes:
  - "8b. Quit": doom_test.py holds Q and expects an immediate cold restart.
    The kiosk build ships with EXHIBIT=1, where Q is compiled out entirely
    (see vzdoom_kiosk.asm's build-config comment) — holding Q there should
    do nothing, not quit. Q-quit is still verified below, against a
    locally-assembled EXHIBIT=0 build, so the *mechanism* stays covered.
  - "9c. Death": doom_test.py expects the game to freeze forever on death.
    The kiosk build's death screen still halts progress, but now blocks on
    an explicit "press SPACE" title/controls screen rather than a bare
    freeze, and respawns instead of staying dead. That's the headline
    feature, not a regression — replaced below with a scenario that
    verifies the respawn actually works: die, wait for the title screen,
    press SPACE, confirm health and demons come back.

One thing this simulator can't tell you anything about: whether the actual
VRAM mode-switch and text rendering look right on real hardware. It has no
dynamic model of the frame-sync line (MMIO bit 7 stays fixed for the whole
run), so WAITFS's bounded-timeout path is exercised here, not its "properly
synced to a real frame edge" path. Treat this file as proof the engine
underneath is unbroken, not as proof the kiosk screen renders correctly on
a CRT.
"""
import os, sys, subprocess

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z80sim import Z80
import gen_tables as g
from gen_tables import s16s

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOAD = 0x7AE9

KROW0, KROW1, KROW4 = 0x68FE, 0x68FD, 0x68EF
W     = (KROW0, 0x02)
E     = (KROW0, 0x08)
S     = (KROW1, 0x02)
D     = (KROW1, 0x08)
A     = (KROW1, 0x10)
DOT   = (KROW4, 0x02)
COMMA = (KROW4, 0x08)
SPACE = (KROW4, 0x10)

SYMS = {}
for line in open(os.path.join(ROOT, "build", "vzdoom_kiosk.sym")):
    parts = line.replace(":", "").split()
    if len(parts) >= 3 and parts[1] == "EQU":
        SYMS[parts[0]] = int(parts[2], 16)

DOOR_LEFT = 9 * 16 + 4

def run_script(script, total, pokes=(), freeze_ok=False, limit=600_000_000):
    """pokes: (frame, addr, [bytes]) — test fixtures applied at that frame
    boundary. freeze_ok: the game may stop reaching MAIN (death freeze)."""
    mem = bytearray(65536)
    code = open(os.path.join(ROOT, "build", "vzdoom_kiosk.bin"), "rb").read()
    mem[LOAD:LOAD + len(code)] = code
    for addr in range(0x6800, 0x7000):
        mem[addr] = 0xFF
    mem[KROW4] = 0xFF & ~0x10   # kiosk_kiosk.asm blocks on a title screen
                                # before ever reaching MAIN the first time;
                                # the harness only injects keys once MAIN
                                # is reached, so pre-hold SPACE here to get
                                # past the boot screen the same way a
                                # player's first keypress would.
    cpu = Z80(mem)
    cpu.pc = LOAD
    main_addr = SYMS["MAIN"]
    hits = 0
    while cpu.icount < limit:
        if cpu.pc == main_addr:
            if hits >= total:
                break
            for frame, addr, data in pokes:
                if frame == hits:
                    mem[addr:addr + len(data)] = bytes(data)
            for addr in (KROW0, KROW1, KROW4):
                mem[addr] = 0xFF
            for rng, keys in script:
                if rng[0] <= hits < rng[1]:
                    for addr, mask in keys:
                        mem[addr] &= ~mask & 0xFF
            hits += 1
        cpu.step()
    else:
        if not freeze_ok:
            raise SystemExit("instruction limit hit")
    return mem


def state(mem):
    px = mem[SYMS["PXV"]] | (mem[SYMS["PXV"] + 1] << 8)
    py = mem[SYMS["PYV"]] | (mem[SYMS["PYV"] + 1] << 8)
    return px, py, mem[SYMS["PANGV"]]

def enemies_of(mem):
    out = []
    for i in range(3):
        ex = mem[SYMS["ENEMX"] + 2*i] | (mem[SYMS["ENEMX"] + 2*i + 1] << 8)
        ey = mem[SYMS["ENEMY"] + 2*i] | (mem[SYMS["ENEMY"] + 2*i + 1] << 8)
        out.append((ex, ey, mem[SYMS["ENALIV"] + i]))
    return out

def check_render(mem, label):
    px, py, pang = state(mem)
    live_map = bytearray(mem[SYMS["MAP"]:SYMS["MAP"] + 256])
    flash = mem[SYMS["FLASH"]] > 0
    dbuf = [0] * 32
    ref = g.cast_frame(px, py, pang, live_map, depth=dbuf)
    g.render_enemies(ref, dbuf, px, py, pang, enemies_of(mem))
    g.draw_gun(ref, flash=flash)
    g.draw_hud(ref, mem[SYMS["HLTH"]], mem[SYMS["KILLS"]], mem[SYMS["FSTATE"]])
    vram = bytes(mem[0x7000:0x7800])
    diffs = sum(1 for i in range(2048) if vram[i] != ref[i])
    ok = diffs == 0
    alive = sum(1 for _, _, a in enemies_of(mem) if a)
    print(f"  {label}: pos=({px/256:.3f},{py/256:.3f}) hp={mem[SYMS['HLTH']]} "
          f"alive={alive} render {'MATCH' if ok else f'{diffs} DIFFS'}")
    return ok

# ── Python mirrors of the Z80 game rules ─────────────────────────────────────

def ai_mirror(enemies, px, py, frames, game_map):
    """Static-player AI mirror: exact cadence, thresholds, order, cell tests,
    including the no-two-demons-per-cell exclusion."""
    ens = [list(e) for e in enemies]

    def occupied(cell, self_i):
        for j in range(3):
            if j == self_i or not ens[j][2]:
                continue
            jc = (((ens[j][1] >> 8) & 15) << 4) | ((ens[j][0] >> 8) & 15)
            if jc == cell:
                return True
        return False

    fcnt = 0
    for _ in range(frames):
        fcnt = (fcnt + 1) & 0xFF
        i = fcnt & 3
        if i >= 3 or not ens[i][2]:
            continue
        ex, ey = ens[i][0], ens[i][1]
        d = s16s(px - ex)
        step = 32 if d >= 96 else (-32 if d <= -96 else 0)
        if step:
            nx = (ex + step) & 0xFFFF
            cell = (((ey >> 8) & 15) << 4) | ((nx >> 8) & 15)
            if game_map[cell] == 0 and not occupied(cell, i):
                ex = nx
        d = s16s(py - ey)
        step = 32 if d >= 96 else (-32 if d <= -96 else 0)
        if step:
            ny = (ey + step) & 0xFFFF
            cell = (((ny >> 8) & 15) << 4) | ((ex >> 8) & 15)
            if game_map[cell] == 0 and not occupied(cell, i):
                ey = ny
        ens[i][0], ens[i][1] = ex, ey
    return [tuple(e) for e in ens]

def firehit_mirror(mem):
    """Exact FIREHIT rule: nearest alive enemy in cols 14-17 in front of the
    wall; ties keep the earliest index. Returns index or None."""
    besti, bestc = None, 255
    for i in range(3):
        if not mem[SYMS["ENALIV"] + i]:
            continue
        col = mem[SYMS["ECOLA"] + i]
        if not (14 <= col <= 17):
            continue
        corr = mem[SYMS["ECORRA"] + i]
        if (corr - (corr >> 3)) >= mem[SYMS["DBUF"] + col]:
            continue
        if bestc <= corr:
            continue
        besti, bestc = i, corr
    return besti

passed = True

# 1. Idle: demons exist but are all behind the wall/doors — render must match
mem = run_script([], 2)
assert state(mem) == (0x0780, 0x0280, 64), f"idle moved: {state(mem)}"
passed &= check_render(mem, "idle+demons hidden ")

# 2. Static player, 80 frames: AI mirror must predict all demon positions
mem = run_script([], 80)
expect = ai_mirror([(0x0480, 0x0C80, 1), (0x0A80, 0x0C80, 1), (0x0780, 0x0D80, 1)],
                   0x0780, 0x0280, 80, bytearray(mem[SYMS["MAP"]:SYMS["MAP"] + 256]))
got = enemies_of(mem)
assert got == expect, f"AI mismatch:\n got {got}\n exp {expect}"
passed &= check_render(mem, "AI 80f (mirrored)  ")

# 3. Movement regression with demons active
mem = run_script([((0, 20), [W])], 20)
assert state(mem)[:2] == (0x0780, 0x0280 + 20 * 32), f"walk: {state(mem)}"
passed &= check_render(mem, "W x20              ")

# 4. Door route: open, walk through — demons will be near/through the doorway
script = [((0, 48), [W]), ((48, 72), [COMMA]), ((72, 73), [E]), ((73, 93), [W])]
mem = run_script(script, 93)
px, py, _ = state(mem)
assert (px, py) == (0x0480, 0x0B00), f"through-door pos: {px:04X},{py:04X}"
assert mem[SYMS["MAP"] + DOOR_LEFT] == 0, "door did not open"
passed &= check_render(mem, "through door+demons")

# 5. Auto-close with demons around
mem = run_script(script, 160)
assert mem[SYMS["MAP"] + DOOR_LEFT] == 2, "door did not auto-close"
passed &= check_render(mem, "door auto-close    ")

# 6. Fire at nothing (all demons behind walls at spawn): no kill
mem = run_script([((0, 1), [SPACE])], 3)
assert all(a for _, _, a in enemies_of(mem)), "killed a hidden demon?!"
passed &= check_render(mem, "fire miss (walled) ")

# 7. Hitscan mirror: idle long enough for demons to reach the wall, then walk
#    to the door, open it, back up, and fire when one is in the gun columns.
script7 = [((0, 48), [W]), ((48, 72), [COMMA]), ((72, 73), [E]), ((73, 85), [S])]
pre = run_script(script7, 140)                       # state just before firing
expected_kill = firehit_mirror(pre)
mem = run_script(script7 + [((140, 141), [SPACE])], 143)
alive_pre = [a for _, _, a in enemies_of(pre)]
alive_post = [a for _, _, a in enemies_of(mem)]
if expected_kill is None:
    assert alive_pre == alive_post, "kill happened but mirror predicted none"
    print(f"  fire@140: mirror predicts MISS - confirmed ({alive_post})")
else:
    assert alive_post[expected_kill] == 0, \
        f"mirror predicted kill of {expected_kill}, but alive={alive_post}"
    assert sum(alive_pre) - sum(alive_post) == 1, "exactly one kill expected"
    print(f"  fire@140: mirror predicts kill of demon {expected_kill} - confirmed")
passed &= check_render(mem, "post-fire          ")

# 8a. Edge clipping: demon just past the left FOV edge — partial columns only
pokes_edge = [(2, SYMS["ENEMX"], [0x80, 0x06]),   # demon 0 -> (6.5, 3.5)
              (2, SYMS["ENEMY"], [0x80, 0x03])]
mem = run_script([], 4, pokes=pokes_edge)
passed &= check_render(mem, "edge-clipped demon ")

# 8b. Quit: Q returns to the reset vector, but only in a non-kiosk build.
# The shipped kiosk build has EXHIBIT=1 (Q compiled out entirely), so this
# builds a throwaway EXHIBIT=0 variant on the fly to verify the mechanism
# itself still works correctly when it's compiled in.
print("  Q quit (EXHIBIT=0 build): ", end="")
src = open(os.path.join(ROOT, "src", "vzdoom_kiosk.asm")).read()
assert "EXHIBIT  EQU    1" in src, "EXHIBIT flag line not found as expected"
src0 = src.replace("EXHIBIT  EQU    1", "EXHIBIT  EQU    0", 1)
src0 = src0.replace('SAVEBIN "build/vzdoom_kiosk.bin"',
                     'SAVEBIN "build/_kiosk_q_tmp.bin"', 1)
tmp_asm = os.path.join(ROOT, "src", "_kiosk_q_tmp.asm")
open(tmp_asm, "w").write(src0)
sj = os.path.join(ROOT, "tools", "sjasmplus")
if not os.path.exists(sj):
    sj = "sjasmplus"
r = subprocess.run([sj, tmp_asm], cwd=ROOT, capture_output=True, text=True)
os.remove(tmp_asm)
assert r.returncode == 0, f"EXHIBIT=0 test build failed:\n{r.stdout}\n{r.stderr}"

mem2 = bytearray(65536)
code2 = open(os.path.join(ROOT, "build", "_kiosk_q_tmp.bin"), "rb").read()
os.remove(os.path.join(ROOT, "build", "_kiosk_q_tmp.bin"))
mem2[LOAD:LOAD + len(code2)] = code2
for addr in range(0x6800, 0x7000):
    mem2[addr] = 0xFF
mem2[KROW0] &= ~0x10 & 0xFF                      # hold Q from the start
cpu2 = Z80(mem2)
cpu2.pc = LOAD
while cpu2.icount < 2_000_000 and cpu2.pc != 0:
    cpu2.step()
assert cpu2.pc == 0, "Q did not reach the reset vector"
assert mem2[0x6800] == 0, f"latch not restored to text mode: {mem2[0x6800]:02X}"
print("reset vector reached, latch=0x00 - confirmed")

# 9. Positive kill: teleport demon 0 dead ahead into the open, then fire
pokes = [(2, SYMS["ENEMX"], [0x80, 0x07]),      # demon 0 -> (7.5, 6.0)
         (2, SYMS["ENEMY"], [0x00, 0x06])]
pre = run_script([], 3, pokes=pokes)
expected_kill = firehit_mirror(pre)
assert expected_kill == 0, f"fixture demon not targetable? mirror={expected_kill}"
passed &= check_render(pre, "demon in the open  ")
mem = run_script([((3, 4), [SPACE])], 6, pokes=pokes)
alive_post = [a for _, _, a in enemies_of(mem)]
assert alive_post[0] == 0 and alive_post[1] == 1 and alive_post[2] == 1, \
    f"expected demon 0 dead: {alive_post}"
print("  fire@3: demon 0 KILLED - confirmed")
passed &= check_render(mem, "after the kill     ")

# 9a2. Eye glance: at frame 45 the clock reads 46 -> phase 5 -> variant R1
mem = run_script([], 46)
assert mem[SYMS["FSTATE"]] == 5, f"eye variant wrong: {mem[SYMS['FSTATE']]}"
passed &= check_render(mem, "eyes glancing right")

# 9b. Bite: demon adjacent from frame 2; bites land every 13 frames
#     (frames 2, 15, 28 in a 32-frame run) -> health 100-24=76
pokes_bite = [(2, SYMS["ENEMX"], [0x80, 0x07]),     # demon 0 -> (7.5, 2.875)
              (2, SYMS["ENEMY"], [0xE0, 0x02])]
mem = run_script([], 32, pokes=pokes_bite)
assert mem[SYMS["HLTH"]] == 76, f"bite health wrong: {mem[SYMS['HLTH']]}"
passed &= check_render(mem, "bitten x3          ")

# 9c. Death + respawn: health poked to 8, one bite kills. Unlike the base
# game (which freezes forever here), the kiosk build should block on the
# title/controls screen and then respawn — full health, all 3 demons back
# up — once SPACE is pressed. This drives the CPU by hand rather than via
# run_script, since the death screen blocks *before* the next arrival at
# MAIN, which is the only point run_script knows how to inject keys at.
print("  death + respawn: ", end="")
mem = bytearray(65536)
code = open(os.path.join(ROOT, "build", "vzdoom_kiosk.bin"), "rb").read()
mem[LOAD:LOAD + len(code)] = code
for addr in range(0x6800, 0x7000):
    mem[addr] = 0xFF
mem[KROW4] = 0xFF & ~0x10                        # past the boot screen
cpu = Z80(mem)
cpu.pc = LOAD
main_addr = SYMS["MAIN"]
wait_addr = SYMS["INFOSCR.wait"]
pokes_death = [(2, SYMS["ENEMX"], [0x80, 0x07]),
               (2, SYMS["ENEMY"], [0xE0, 0x02]), (2, SYMS["HLTH"], [8])]
hits = 0
seen_main = False
space_sent = False
limit = 40_000_000
while cpu.icount < limit:
    if cpu.pc == main_addr:
        seen_main = True
        if hits < 4:                             # let death actually occur
            for frame, addr, data in pokes_death:
                if frame == hits:
                    mem[addr:addr + len(data)] = bytes(data)
            for addr in (KROW0, KROW1, KROW4):
                mem[addr] = 0xFF
            hits += 1
        elif space_sent:
            break                                 # back in MAIN post-respawn
    if seen_main and cpu.pc == wait_addr and not space_sent:
        mem[KROW4] &= ~0x10 & 0xFF                # "player" presses SPACE
        space_sent = True
    cpu.step()
else:
    raise SystemExit("death+respawn: instruction limit hit before respawn")
assert space_sent, "never reached the title screen after death"
assert mem[SYMS["HLTH"]] == 100, f"respawn didn't heal: HLTH={mem[SYMS['HLTH']]}"
alive = [mem[SYMS["ENALIV"] + i] for i in range(3)]
assert alive == [1, 1, 1], f"respawn didn't revive all demons: {alive}"
print(f"HLTH=100, demons {alive} - confirmed")


# 10. Projection sweep: silicon EPROJ vs Python across a position grid.
#     (Would have caught the 9-bit-remainder division bug.) One long run;
#     demon 0 teleported each frame, read back post-AI position + projection.
print("  projection sweep: ", end="")
positions = []
for dx in (-1696, -1024, -640, -320, -96, 0, 96, 320, 640, 1024, 1696):
    for dy in (-1024, -320, -96, 96, 320, 640, 1024, 1792):
        positions.append(((0x0780 + dx) & 0xFFFF, (0x0280 + dy) & 0xFFFF))

mem = bytearray(65536)
code = open(os.path.join(ROOT, "build", "vzdoom_kiosk.bin"), "rb").read()
mem[LOAD:LOAD + len(code)] = code
for addr in range(0x6800, 0x7000):
    mem[addr] = 0xFF
mem[KROW4] = 0xFF & ~0x10   # KIOSK ADD: skip the boot title screen, see above
cpu = Z80(mem)
cpu.pc = LOAD
main_addr = SYMS["MAIN"]
hits = 0
mismatches = 0
checked = 0
while cpu.icount < 2_000_000_000:
    if cpu.pc == main_addr:
        if hits >= 2:
            k = hits - 2
            if k > 0 and k - 1 < len(positions):
                # read back last frame's post-AI position and its projection
                ex = mem[SYMS["ENEMX"]] | (mem[SYMS["ENEMX"] + 1] << 8)
                ey = mem[SYMS["ENEMY"]] | (mem[SYMS["ENEMY"] + 1] << 8)
                px = mem[SYMS["PXV"]] | (mem[SYMS["PXV"] + 1] << 8)
                py = mem[SYMS["PYV"]] | (mem[SYMS["PYV"] + 1] << 8)
                pang = mem[SYMS["PANGV"]]
                exp_col, exp_corr = g.project_enemy(px, py, pang, ex, ey)
                got_col, got_corr = mem[SYMS["ECOLA"]], mem[SYMS["ECORRA"]]
                checked += 1
                if got_col != (exp_col & 0xFF) or got_corr != exp_corr:
                    mismatches += 1
                    if mismatches <= 5:
                        print(f"\n    MISMATCH demon@({ex/256:.3f},{ey/256:.3f}): "
                              f"asm=({got_col},{got_corr}) "
                              f"py=({exp_col & 0xFF},{exp_corr})", end="")
            if k >= len(positions):
                break
            ex, ey = positions[k]
            mem[SYMS["ENEMX"]:SYMS["ENEMX"] + 2] = bytes([ex & 0xFF, ex >> 8])
            mem[SYMS["ENEMY"]:SYMS["ENEMY"] + 2] = bytes([ey & 0xFF, ey >> 8])
        for addr in (KROW0, KROW1, KROW4):
            mem[addr] = 0xFF
        hits += 1
    cpu.step()
print(f"{checked} positions, {mismatches} mismatches "
      f"{'- PASS' if mismatches == 0 else '- FAIL'}")
passed &= (mismatches == 0 and checked == len(positions))

print()
print("ALL PASS" if passed else "FAILURES — see above")
sys.exit(0 if passed else 1)
