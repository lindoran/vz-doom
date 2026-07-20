# VZ-DOOM — Design Document

A DOOM-flavoured 3D maze shooter for the Dick Smith VZ200. Because it's there.

## Reality check (agreed earlier)

Real DOOM (BSP engine) cannot run on a Z80 — it assumed a 32-bit CPU and 4MB
RAM. What CAN run, and has precedent on 3.5MHz Z80 machines, is a
**Wolfenstein-style raycaster**: grid map, vertical wall slices, flat-shaded
walls with dither for depth. Target: **4–6 fps** at 128×64, 4 colours.

## Two-tier plan

- **Tier 2 "purist"** (this document): everything on the Z80. Mode 1 graphics,
  raycast in assembly, LUTs in RAM. The real deal.
- **Tier 3 "glory"** (later): same Z80 game logic, but it also streams compact
  game state (player x/y/angle, entities) to a spare RAM "mailbox" region.
  The Pico2W — which already sees every memory write — renders a textured,
  smooth 3D view to HDMI. The VZ plays the game; the Pico is its GPU.
  The existing capture path IS the mailbox transport; nothing new needed
  on the wire.

## Hardware inventory

| Resource | Detail |
|---|---|
| CPU | Z80A @ 3.58MHz (~716K T-states per frame at 5fps) |
| Screen | Mode 1: 128×64, 2bpp, 2KB at $7000–$77FF, 32 bytes/row |
| Colours | CSS=0: green/yellow/blue/red · CSS=1: buff/cyan/magenta/orange |
| Mode latch | $6800–$6FFF write: b3=mode, b4=CSS (write also from ROM IRQ — run with DI) |
| Base RAM | $7800–$8FFF (6KB) — code + variables + stack |
| SD loader RAM | 128KB banked at $9000–$FFFF (port 55=0 VZ200 map; port 58 b1/b2 bank select) — LUTs, map, later level streaming |
| Keyboard | Memory-mapped READS $6800–$6FFF rows — reads are invisible to the Pico shadow, no interference |
| Telemetry | Pico serial stats = free profiler: vram/s ÷ 2048 ≈ fps during full-screen redraws |

## Renderer architecture (Tier 2)

Classic raycaster, byte-column granularity for v0:

1. **32 rays** (one per VRAM byte column = 4px wide) cast from player through
   a 16×16 grid map using integer DDA.
2. Per ray: distance → wall height via LUT (128 entries), height → ceiling
   count via LUT.
3. **Column renderer**: write ceiling bytes (colour 0), wall bytes (dither
   pattern by distance band: solid / 75% / 50% / sparse), floor bytes
   (colour 1). 64 writes of (HL),A with ADD HL,DE(32) per column.
4. Wall N/S vs E/W faces get different patterns — free "lighting".

### Budget (per frame, 3.58MHz)

| Stage | T-states |
|---|---|
| 32 × DDA raycast (~15 steps × ~180T) | ~90K |
| 32 × column render (64 rows × 31T + overhead) | ~68K |
| Input + movement + game tick | ~20K |
| **Total** | **~180K → ~20fps ceiling, 8–10fps realistic with textures/sprites off** |

Better than the 5fps promise. Double-width rays (16 rays, 8px columns) is the
fallback if the budget slips.

### Fixed-point conventions

- Positions: 8.8 fixed point (map is 16×16, so high byte = cell, low = frac)
- Angles: 256 units per revolution (1 byte), sin/cos tables 256×16-bit in
  banked RAM (aligned 256 for H,L=table,index addressing)
- Distances: 8.8; wall height LUT indexed by distance high bits

## Milestones

- **M0 — toolchain** ✅ sjasmplus 1.23.1 + build.ps1 (.asm → .VZ autostart)
- **M1 — wavedemo** ✅ column renderer measured **50.95 fps** on hardware
  (predicted 50); capture path clean at 663K samples/s
- **M2 — raycast** ✅ code-complete, **simulator-verified byte-exact** vs the
  Python reference (frame 1 at PANG=64 and frame 6 at PANG=65 both match all
  2048 VRAM bytes). `src/raycast.asm` + `tools/gen_tables.py` (tables + ref
  renderer) + `tools/z80sim.py` (minimal Z80 interpreter harness).
  Slow auto-rotation (1 unit / 4 frames). ~49.2K instructions ≈ 330K T-states
  per frame → predicted **~10–11 fps**. Awaiting hardware test.
- **M3 — movement** ✅ code-complete, simulator-verified (`src/walk.asm` →
  WALK.VZ). Controls: W/S forward/back, A/D turn (2 units/frame), ,/. strafe.
  Movement = step tables reused (1/8 cell/frame); collision tests X and Y
  independently → Wolf3D wall sliding. Keyboard = memory-mapped reads
  ($68FE W · $68FD A/D/S · $68EF ,/.), invisible to the Pico capture.
  Verified via `tools/walk_test.py`: 6 scripted-input scenarios (idle
  regression, walk, wall stop at exact fixed-point boundary, turn, strafe,
  turn+walk), every frame byte-exact vs the Python reference. Awaiting
  hardware test.
- **M4 — doors, gun, sound** ✅ code-complete, simulator-verified
  (`src/vzdoom.asm` → VZDOOM.VZ). Doors: cell type 2 (render $DD), E opens
  the cell 0.5 ahead, auto-close 75 frames, held open while occupied, one
  door tracked at a time. Weapon: 16×16 masked sprite blit bottom-centre,
  SPACE fires (4-frame flash, 10-frame cooldown). Sound: BEEP via latch
  bits 0/5 preserving b3/b4 — footstep every 8th moving frame, door whoosh,
  fire blip (audible on Pico capture too!). 7 sim scenarios ALL PASS incl.
  auto-close behind player and door-held-open-while-standing-in-it.
  Deferred to M5: 50Hz movement pacing via 6847 FS bit (probe first from
  BASIC: does PEEK(26622) bit 6 or 7 toggle at 50Hz?).
- **M5 — enemies** ✅ code-complete, simulator-verified (10 scenarios ALL
  PASS: byte-exact demon rendering, 80-frame AI mirror, negative AND positive
  hitscan mirror with a confirmed kill). 3 demons spawn in the rooms behind
  the doors and chase (1/8 cell per 4 frames each, round-robin cadence
  FCNT&3, X/Y independent steps = wall sliding; doors block them — open a
  door and they come through, and it closes behind them).
  Projection: octant-folded atan2 (ATAN5 LUT + restoring 16÷8 divide) +
  octagonal distance (max + min/2), then the SAME FISH/HLUT pipeline as
  walls, so sprite depth compares directly against the per-column depth
  buffer (DBUF page, filled during the wall pass). Three pre-scaled
  blue-outlined sprites (24/16/8 px) by distance band (<20/<40/else),
  floor-grounded — bands guarantee no vertical clipping. Draw far→near,
  strict-> lowest-index tie rule (Python reference mirrors it exactly).
  SPACE hitscan: nearest alive demon in gun columns 14–17 and in front of
  the wall. Demons hover diagonally at standoff (per-axis 0.375-cell
  threshold), so you genuinely have to aim. Death = long falling wail.
  **NOTE: CODEEND $8EE1 — ~280 bytes of stack headroom left. Base RAM is
  essentially full; M6+ content must move to SD-loader banked RAM.**
- **M6 — game**: HUD (health/ammo), demon damage to the player, more maps
  via banked RAM / SD, difficulty. Also still pending: 50Hz pacing probe.
- **M7 — Tier 3 mailbox**: state block (player + demons + doors) written to
  spare RAM each frame; Pico renders the textured HDMI version. The capture
  path is the transport — no new hardware.

## File layout

```
vz_doom/
  DESIGN.md          this file
  build.ps1          assemble + wrap .VZ (usage: .\build.ps1 src\wavedemo.asm NAME)
  tools/sjasmplus.exe
  src/wavedemo.asm   M1 demo
  build/             .bin and .VZ outputs
```

## Open questions

- Confirm SD loader banked RAM timing quirks (none expected — plain SRAM)
- Keyboard matrix rows for chosen movement keys (VZ tech manual has the map)
- Does the SD loader CLI autorun `VZDOS.VZ`? Could autoboot straight into
  the game for demo effect ("DOOM cartridge")
