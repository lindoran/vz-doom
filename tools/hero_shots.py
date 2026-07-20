#!/usr/bin/env python3
"""Render README hero images through the real pipeline (current M6 geometry)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_tables as g

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "docs", "images")
os.makedirs(OUT, exist_ok=True)

def shot(name, px, py, pang, enemies, health, kills, flash=False, scale=3):
    dbuf = [0] * 32
    v = g.cast_frame(px, py, pang, depth=dbuf)
    g.render_enemies(v, dbuf, px, py, pang, enemies)
    g.draw_gun(v, flash=flash)
    g.draw_hud(v, health, kills, g.face_state(health, 6 if flash else 0))
    g.vram_to_png(v, os.path.join(OUT, name), sx=2 * scale, sy=3 * scale)

# healthy: a demon dead ahead, full health, gun up
shot("gameplay.png", 0x0780, 0x0480, 64, [(0x0780, 0x0680, 1)], 100, 0)
# firing at a close demon, bloodied
shot("firefight.png", 0x0480, 0x0880, 64, [(0x0480, 0x0a00, 1),
     (0x0680, 0x0980, 1)], 28, 1, flash=True)
print("hero shots written to docs/images/")
