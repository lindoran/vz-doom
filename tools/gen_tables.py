#!/usr/bin/env python3
"""
gen_tables.py — VZ-DOOM M2 raycaster: table generator + reference renderer.

Generates src/tables.inc (map, trig, fisheye, height LUTs) and renders the
expected first frame with EXACTLY the integer math the Z80 code performs.
Outputs build/ref_vram.bin (2048 bytes, ground truth for the emulator test)
and build/ref.png (human-viewable).
"""
import math, os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── World / engine constants (must match raycast.asm) ───────────────────────
PX, PY  = 0x0780, 0x0280        # player at (7.5, 2.5), 8.8 fixed point
PANG    = 64                    # facing +Y
VIEW_H  = 52                    # 3D view rows 0..51; rows 52-63 = HUD panel
HORIZON = 26
K_WALL  = 400                   # height numerator: h = K/d (d in 1/8 cells)

# Map: 16x16, row y=15 first here (printed top-down), '#'=wall, '2'=door
MAP_ROWS = [
    "################",   # y15
    "#..............#",   # y14
    "#....##..##....#",   # y13
    "#..............#",   # y12
    "#.....#..#.....#",   # y11
    "#.....#..#.....#",   # y10
    "####2#####2#####",   # y9  <- doors at x4 and x10
    "#..............#",   # y8
    "#...#......#...#",   # y7
    "#...#......#...#",   # y6
    "#..............#",   # y5
    "#.##........##.#",   # y4
    "#..............#",   # y3
    "#..............#",   # y2  <- player row
    "#..............#",   # y1
    "################",   # y0
]
MAP = bytearray(256)
for i, row in enumerate(MAP_ROWS):
    y = 15 - i
    assert len(row) == 16
    for x, ch in enumerate(row):
        MAP[y * 16 + x] = {'#': 1, '2': 2}.get(ch, 0)
# border must be solid — the ray marcher relies on it
assert all(MAP[0*16+x] and MAP[15*16+x] for x in range(16))
assert all(MAP[y*16+0] and MAP[y*16+15] for y in range(16))

# ── Tables ───────────────────────────────────────────────────────────────────
def s16(v):  return v & 0xFFFF

STEPX = [s16(round(32 * math.cos(a * 2 * math.pi / 256))) for a in range(256)]
STEPY = [s16(round(32 * math.sin(a * 2 * math.pi / 256))) for a in range(256)]
FISH  = [min(255, round(256 * math.cos((31 - 2*c) * 2 * math.pi / 256)))
         for c in range(32)]
def hlut(d):
    if d == 0: return 50
    return max(2, min(50, round(K_WALL / d))) & 0xFE
HLUT = [hlut(d) for d in range(256)]

# atan(i/32) in 256-per-rev angle units, i = 0..32 (0..45 deg -> 0..32 units)
ATAN5 = [round(math.atan(i / 32) * 256 / (2 * math.pi)) for i in range(33)]

def udiv(dividend, divisor):
    """Mirrors the Z80 16/8 restoring division exactly (= floor division)."""
    return dividend // divisor

def enemy_angle_dist(dx, dy):
    """Octant-folded atan2 + octagonal distance, exactly as the Z80 does it.
    dx, dy: signed cell-space deltas in 8.8. Returns (angle 0-255, dist8) or
    None when the enemy is on top of the player."""
    adx, ady = abs(dx), abs(dy)
    if adx == 0 and ady == 0:
        return None
    # octagonal magnitude: max + min/2, scaled 8.8 -> 1/8-cell units
    mx, mn = (adx, ady) if adx >= ady else (ady, adx)
    dist8 = min(255, (mx + (mn >> 1)) >> 5)
    # normalise for the 8-bit divisor
    while mx > 255:
        mx >>= 1
        mn >>= 1
    base = ATAN5[udiv(mn << 5, mx) if mx else 32]
    if adx >= ady:
        if dx > 0:  a = base if dy >= 0 else (256 - base)
        else:       a = (128 - base) if dy >= 0 else (128 + base)
    else:
        if dy > 0:  a = (64 - base) if dx >= 0 else (64 + base)
        else:       a = (192 + base) if dx >= 0 else (192 - base)
    return a & 0xFF, dist8

# ── Reference raycast (mirrors the Z80 instruction-for-instruction) ─────────
CEIL_B, FLOOR_B, WALL_FRONT, WALL_SIDE = 0x00, 0x55, 0xFF, 0xAA  # red / blue
DOOR_B = 0xDD                                    # red/yellow panels, both faces

def cast_frame(px, py, pang, game_map=None, depth=None):
    """depth: optional 32-entry list — filled with per-column corrected dist."""
    m = game_map if game_map is not None else MAP
    vram = bytearray(2048)
    for col in range(32):
        a  = (pang + 31 - 2 * col) & 0xFF
        sx, sy = STEPX[a], STEPY[a]
        x, y, d = px, py, 0
        while True:
            x = s16(x + sx)
            xcell = (x >> 8) & 15
            y = s16(y + sy)
            ycell = (y >> 8) & 15
            d = (d + 1) & 0xFF
            cell = m[(ycell << 4) | xcell]
            if cell:
                break
        if cell == 2:
            wall = DOOR_B
        else:
            xprev = ((s16(x - sx)) >> 8) & 15
            wall  = WALL_SIDE if xprev != xcell else WALL_FRONT
        corr  = (d * FISH[col]) >> 8
        if depth is not None:
            depth[col] = corr & 0xFF
        h     = HLUT[corr & 0xFF]
        ceil  = (VIEW_H - h) >> 1
        for row in range(VIEW_H):
            if   row <  ceil:     b = CEIL_B
            elif row <  ceil + h: b = wall
            else:                 b = FLOOR_B
            vram[row * 32 + col] = b
    return vram

# ── Weapon sprite: 16x16 px at byte-columns 14-17, rows 48-63 ───────────────
# '.'=transparent, digits = colour index (0 green, 1 yellow, 2 blue, 3 red)
GUN_ART = [
    "................",
    "................",
    "................",
    "................",
    "......22........",
    "......22........",
    "......22........",
    ".....2222.......",
    ".....2222.......",
    "....222222......",
    "....2222222.....",
    "...22222222.....",
    "...222222222....",
    "....22222222....",
    "....222222......",
    ".....2222.......",
]
FLASH_ART = [
    "......11........",
    ".....1331.......",
    "....133331......",
    ".....1331.......",
    "......22........",
    "......22........",
    "......22........",
    ".....2222.......",
    ".....2222.......",
    "....222222......",
    "....2222222.....",
    "...22222222.....",
    "...222222222....",
    "....22222222....",
    "....222222......",
    ".....2222.......",
]
GUN_X, GUN_Y = 14, 36       # byte column / pixel row (bottom = view row 51)

def sprite_table(art):
    """Column-major (mask, data) byte pairs — the asm draw order."""
    out = []
    for c in range(4):
        for r in range(16):
            mask = data = 0
            for p in range(4):
                ch = art[r][c * 4 + p]
                shift = 6 - 2 * p
                if ch == '.':
                    mask |= 3 << shift
                else:
                    data |= int(ch) << shift
            out += [mask, data]
    return out

GUNSPR, FLSSPR = sprite_table(GUN_ART), sprite_table(FLASH_ART)

# ── Demon: 24x24 base art, nearest-scaled to 16x16 and 8x8 ──────────────────
DEMON_ART = [
    "........33333333........",
    ".......3333333333.......",
    "..3...333333333333...3..",
    "..33.33331333313333.33..",
    "...3333331333313333333..",
    "...33333333333333333....",
    "....333333333333333.....",
    "....333311333311333.....",
    "....333313333313333.....",
    ".....33333322333333.....",
    ".....33332222223333.....",
    "......333222222333......",
    "......333322223333......",
    ".....3333333333333......",
    "....333333333333333.....",
    "...33.3333333333.333....",
    "..33...33333333...33....",
    ".33....33333333....33...",
    ".......3333333..........",
    "......333..3333.........",
    ".....333....333.........",
    "....333......333........",
    "...333........333.......",
    "..333..........333......",
]

def outline_art(art, colour='1'):
    """Body pixels that touch transparency (or the border) become `colour` —
    a contrast outline so the sprite reads against same-coloured walls."""
    h, w = len(art), len(art[0])
    out = []
    for r in range(h):
        row = ""
        for c in range(w):
            ch = art[r][c]
            if ch != '.':
                edge = (r == 0 or r == h - 1 or c == 0 or c == w - 1 or
                        '.' in (art[r-1][c], art[r+1][c],
                                art[r][c-1], art[r][c+1]))
                row += colour if edge else ch
            else:
                row += ch
        out.append(row)
    return out

def scale_art(art, size):
    src = len(art)
    return ["".join(art[r * src // size][c * src // size]
                    for c in range(size)) for r in range(size)]

def sprite_table_wh(art, wcols, hrows):
    out = []
    for c in range(wcols):
        for r in range(hrows):
            mask = data = 0
            for p in range(4):
                ch = art[r][c * 4 + p]
                shift = 6 - 2 * p
                if ch == '.':
                    mask |= 3 << shift
                else:
                    data |= int(ch) << shift
            out += [mask, data]
    return out

# ── HUD: panel rows 52-63, face 16x12 at byte cols 14-17, pips, kill tally ──
# Face art: '.'=panel(blue), 1=skin(yellow), 2=hair/shadow(blue), 3=blood/red
FACE_OK = [
    "..222222222222..",
    ".22222222222222.",
    ".22111111111122.",
    ".21111111111112.",
    ".21121111211112.",
    ".21121111211112.",
    ".21111111111112.",
    ".21111221111112.",
    ".21111111111112.",
    ".21131111131112.",
    ".21113333311112.",
    "..211111111112..",
]
FACE_MEH = [
    "..222222222222..",
    ".22222222222222.",
    ".22111311111122.",
    ".21111311111112.",
    ".21121111211112.",
    ".21121111211112.",
    ".21111111113112.",
    ".21111221113112.",
    ".21311111111112.",
    ".21133333331112.",
    ".21113111311112.",
    "..211111111112..",
]
FACE_BAD = [
    "..222222222222..",
    ".22222322232222.",
    ".22131311131122.",
    ".21113111311312.",
    ".21121311211312.",
    ".21321111213112.",
    ".21311131113112.",
    ".21111221111312.",
    ".21331113311112.",
    ".21333333333112.",
    ".21313131313312.",
    "..231111111132..",
]
FACE_OUCH = [
    "..222222222222..",
    ".22222222222222.",
    ".22112222211122.",
    ".21111111111112.",
    ".21122111221112.",
    ".21122111221112.",
    ".21111111111112.",
    ".21111331111112.",
    ".21113333111112.",
    ".21133333311112.",
    ".21133333311112.",
    "..211333331112..",
]
FACE_DEAD = [
    "..222222222222..",
    ".22222222222222.",
    ".22111111111122.",
    ".21211211212112.",
    ".21121111121112.",
    ".21211211212112.",
    ".21111111111112.",
    ".21111111111112.",
    ".21133333331112.",
    ".21311111113112.",
    ".21111111111112.",
    "..211111111112..",
]
def eye_shift(art, rows, d):
    """Move the eye pixels (cols 4 and 9 in the base art) sideways by d."""
    out = [list(r) for r in art]
    for r in rows:
        for eye in (4, 9):
            out[r][eye] = '1'
            out[r][eye + d] = '2'
    return ["".join(r) for r in out]

# Eye glance variants of the healthy face: bottom pixel leads, top follows
FACE_R1 = eye_shift(FACE_OK, (5,), 1)       # bottom px right
FACE_R2 = eye_shift(FACE_OK, (4, 5), 1)     # both right
FACE_L1 = eye_shift(FACE_OK, (5,), -1)
FACE_L2 = eye_shift(FACE_OK, (4, 5), -1)

FACES = [FACE_OK, FACE_MEH, FACE_BAD, FACE_OUCH, FACE_DEAD,
         FACE_R1, FACE_R2, FACE_L1, FACE_L2]

# Healthy-face animation: 16 phases x 8 frames (~8s loop), indices into FACES
EYESEQ = [0, 0, 0, 0, 0, 5, 6, 6, 5, 0, 0, 7, 8, 8, 7, 0]

def face_bytes(art):
    """Opaque 2bpp bytes, column-major (4 cols x 12 rows), panel colour baked."""
    cmap = {'.': 2, '1': 1, '2': 2, '3': 3}
    out = []
    for c in range(4):
        for r in range(12):
            b = 0
            for p in range(4):
                b |= cmap[art[r][c * 4 + p]] << (6 - 2 * p)
            out.append(b)
    return out

FACETABS = [face_bytes(f) for f in FACES]

PANEL_B = 0xAA                      # solid blue panel
PIP_FULL, PIP_EMPTY = 0xFF, 0x55    # red / yellow slot
TALLY_ALIVE = [0x3C, 0xFF, 0xD7, 0xFF, 0xFF, 0x3C]   # red head, yellow eyes
TALLY_DEAD  = [0x14, 0x55, 0x41, 0x55, 0x55, 0x14]   # yellow ghost, green eyes

def draw_hud(vram, health, kills, fstate):
    for row in range(52, 64):                       # panel
        for c in range(32):
            vram[row * 32 + c] = PANEL_B
    tab = FACETABS[fstate]                          # face, byte cols 14-17
    i = 0
    for c in range(4):
        for r in range(12):
            vram[(52 + r) * 32 + 14 + c] = tab[i]
            i += 1
    pips = (health + 19) // 20                      # 5 pips, 20HP each
    for i in range(5):
        b = PIP_FULL if i < pips else PIP_EMPTY
        for r in range(55, 61):
            vram[r * 32 + 2 + 2 * i] = b
    for i in range(3):                              # kill tally, byte cols 20/22/24
        rows = TALLY_DEAD if i < kills else TALLY_ALIVE
        for r in range(6):
            vram[(55 + r) * 32 + 20 + 2 * i] = rows[r]
    return vram

# Damage rules (asm mirrors): bite when any alive demon has |dx|,|dy| < 160;
# then health -= 8 (floor 0), BITET=12 frames, FACET=6 frames (ouch face).
BITE_RANGE, BITE_DMG, BITE_CD, OUCH_T = 160, 8, 12, 6

def face_state(health, facet, eyet=0):
    if health == 0: return 4                        # dead
    if facet > 0:   return 3                        # ouch
    if health > 66: return EYESEQ[(eyet >> 3) & 15] # healthy: glancing eyes
    if health > 33: return 1
    return 2

DEMON_OUTLINED = outline_art(DEMON_ART, colour='2')   # blue outline
DEMON_L = sprite_table_wh(DEMON_OUTLINED, 6, 24)                     # 24px
DEMON_M = sprite_table_wh(scale_art(DEMON_OUTLINED, 16), 4, 16)     # 16px
DEMON_S = sprite_table_wh(scale_art(DEMON_OUTLINED, 8), 2, 8)       # 8px

# Distance bands and geometry — the asm mirrors these numbers
BAND_L, BAND_M = 20, 40                 # corr < 20 -> L, < 40 -> M, else S
SPRITES = {"L": (DEMON_L, 6, 24), "M": (DEMON_M, 4, 16), "S": (DEMON_S, 2, 8)}

def draw_enemy(vram, dbuf, ecol, ecorr):
    """Masked, depth-tested, floor-grounded demon at screen column ecol.
    Occlusion uses a 1/8-deflated depth: the octagonal distance approximation
    overestimates by up to ~12%, which made wall-adjacent demons flicker."""
    tab, w, hrows = SPRITES["L" if ecorr < BAND_L else
                            "M" if ecorr < BAND_M else "S"]
    occl = ecorr - (ecorr >> 3)
    bottom = HORIZON + (HLUT[ecorr & 0xFF] >> 1)    # feet on the floor line
    top = bottom - hrows
    cstart = ecol - (w >> 1)
    for c in range(w):
        sc = cstart + c
        if not (0 <= sc < 32):
            continue
        if dbuf[sc] <= occl:                    # wall in front — skip column
            continue
        for r in range(hrows):
            row = top + r
            if not (0 <= row < 64):
                continue
            mask, data = tab[(c * hrows + r) * 2], tab[(c * hrows + r) * 2 + 1]
            adr = row * 32 + sc
            vram[adr] = (vram[adr] & mask) | data

def project_enemy(px, py, pang, ex, ey):
    """(ecol, ecorr) exactly as the Z80 EPROJ computes it; (100,255) = culled."""
    r = enemy_angle_dist(s16s(ex - px), s16s(ey - py))
    if r is None:
        return (100, 255)
    a, dist8 = r
    rel = (pang + 31 - a) & 0xFF
    if 96 <= rel < 224:                         # more than ~90 deg off-centre
        return (100, 255)
    col = (rel if rel < 128 else rel - 256) >> 1       # signed, -16..47
    fidx = 0 if col < 0 else (31 if col > 31 else col)
    return (col, (dist8 * FISH[fidx]) >> 8)

def render_enemies(vram, dbuf, px, py, pang, enemies):
    """enemies: list of (ex, ey, alive). Far-to-near draw using EXACTLY the
    Z80's selection rule (scan ascending, strict >, so ties go to the lowest
    index). Returns per-enemy (ecol, ecorr); (100,255) = offscreen/dead."""
    stored = []
    for ex, ey, alive in enemies:
        if not alive:
            stored.append((100, 255))
            continue
        stored.append(project_enemy(px, py, pang, ex, ey))
    drawn = [False] * len(stored)
    while True:
        best = -1
        for i in range(len(stored)):
            if drawn[i] or stored[i][0] == 100:
                continue
            if best == -1 or stored[i][1] > stored[best][1]:
                best = i
        if best == -1:
            break
        drawn[best] = True
        draw_enemy(vram, dbuf, stored[best][0], stored[best][1])
    return stored

def s16s(v):
    """16-bit two's complement -> signed int (the Z80 sees deltas this way)."""
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def draw_gun(vram, flash=False):
    tab = FLSSPR if flash else GUNSPR
    i = 0
    for c in range(4):
        for r in range(16):
            mask, data = tab[i], tab[i + 1]
            i += 2
            adr = (GUN_Y + r) * 32 + GUN_X + c
            vram[adr] = (vram[adr] & mask) | data
    return vram

# ── Minimal PNG writer (no dependencies) ─────────────────────────────────────
def write_png(path, w, h, rgb_rows):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    raw = b"".join(b"\x00" + bytes(r) for r in rgb_rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)

PALETTE = [(40, 220, 40), (230, 220, 40), (40, 60, 230), (220, 40, 40)]  # g,y,b,r

def vram_to_png(vram, path, sx=4, sy=6):
    rows = []
    for py_ in range(64):
        row = []
        for bx in range(32):
            b = vram[py_ * 32 + bx]
            for p in range(4):
                c = PALETTE[(b >> (6 - p * 2)) & 3]
                row.extend(c * sx)
        for _ in range(sy):
            rows.append(row)
    write_png(path, 128 * sx, 64 * sy, rows)

# ── Emit tables.inc ──────────────────────────────────────────────────────────
def db_lines(name, data, per=16):
    out = [f"{name}:"]
    for i in range(0, len(data), per):
        out.append("        DB      " + ",".join(f"${b:02X}" for b in data[i:i+per]))
    return "\n".join(out)

inc = f"""; tables.inc — GENERATED by tools/gen_tables.py — DO NOT EDIT BY HAND
; Player start: PX={PX:#06x} PY={PY:#06x} PANG={PANG}
; Pages: MAP, STEPXL, STEPXH, STEPYL, STEPYH consecutive; FISH, HLUT aligned.

        ALIGN   256
{db_lines('MAP', MAP)}

        ALIGN   256
{db_lines('STEPXL', [v & 0xFF for v in STEPX])}
{db_lines('STEPXH', [(v >> 8) & 0xFF for v in STEPX])}
{db_lines('STEPYL', [v & 0xFF for v in STEPY])}
{db_lines('STEPYH', [(v >> 8) & 0xFF for v in STEPY])}

        ALIGN   256
{db_lines('FISH', FISH)}

        ALIGN   256
{db_lines('HLUT', HLUT)}

; Weapon sprites: column-major (mask,data) pairs, 4 cols x 16 rows
{db_lines('GUNSPR', GUNSPR)}
{db_lines('FLSSPR', FLSSPR)}

; atan(i/32) in angle units, i=0..32
{db_lines('ATAN5', ATAN5)}

; HUD faces: opaque bytes, column-major 4x12
; 0-4 = OK/MEH/BAD/OUCH/DEAD, 5-8 = healthy eye glances R1/R2/L1/L2
{db_lines('FACE0', FACETABS[0])}
{db_lines('FACE1', FACETABS[1])}
{db_lines('FACE2', FACETABS[2])}
{db_lines('FACE3', FACETABS[3])}
{db_lines('FACE4', FACETABS[4])}
{db_lines('FACE5', FACETABS[5])}
{db_lines('FACE6', FACETABS[6])}
{db_lines('FACE7', FACETABS[7])}
{db_lines('FACE8', FACETABS[8])}

; kill tally icons, 6 rows each
{db_lines('TLYA', TALLY_ALIVE)}
{db_lines('TLYD', TALLY_DEAD)}

; Demon sprites, column-major (mask,data): L 6x24, M 4x16, S 2x8
{db_lines('DEMON_L', DEMON_L)}
{db_lines('DEMON_M', DEMON_M)}
{db_lines('DEMON_S', DEMON_S)}
"""
open(os.path.join(ROOT, "src", "tables.inc"), "w").write(inc)

# ── Reference outputs ────────────────────────────────────────────────────────
os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
vram = cast_frame(PX, PY, PANG)
open(os.path.join(ROOT, "build", "ref_vram.bin"), "wb").write(vram)
vram_to_png(vram, os.path.join(ROOT, "build", "ref.png"))
vram_to_png(draw_gun(cast_frame(PX, PY, PANG)),
            os.path.join(ROOT, "build", "ref_gun.png"))
vram_to_png(draw_gun(cast_frame(PX, PY, PANG), flash=True),
            os.path.join(ROOT, "build", "ref_flash.png"))

print("tables.inc, ref_vram.bin, ref.png, ref_gun.png, ref_flash.png written")
