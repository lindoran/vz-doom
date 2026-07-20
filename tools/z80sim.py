#!/usr/bin/env python3
"""
z80sim.py — minimal Z80 interpreter, just enough to execute raycast.bin.

Loads build/raycast.bin at its .VZ load address, runs until the MAIN label
has been reached N times (frame boundaries), then dumps VRAM ($7000-$77FF)
to build/emu_vram.bin, renders build/emu.png, and byte-compares against
build/ref_vram.bin (the Python reference frame).

Implements: main-block LD/ALU/INC/DEC/rotates used by the target, JR/JP/DJNZ,
PUSH/POP, EXX, ADD HL,rr, ED SBC HL,rr, CB SRL. Anything else raises.
"""
import os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOAD = 0x7AE9

def load_syms():
    syms = {}
    for line in open(os.path.join(ROOT, "build", "raycast.sym")):
        parts = line.replace(":", "").split()
        if len(parts) >= 3 and parts[1] == "EQU":
            syms[parts[0]] = int(parts[2], 16)
    return syms

class Halt(Exception): pass

class Z80:
    def __init__(self, mem):
        self.m = mem
        self.a = self.f = 0
        self.b = self.c = self.d = self.e = self.h = self.l = 0
        self.b2 = self.c2 = self.d2 = self.e2 = self.h2 = self.l2 = 0
        self.sp = 0xFFFF
        self.pc = 0
        self.icount = 0

    # flags: bit7 S, 6 Z, 4 H, 2 PV, 1 N, 0 C
    def setZ(self, v): self.f = (self.f & ~0x40) | (0x40 if (v & 0xFF) == 0 else 0)
    def setC(self, c): self.f = (self.f & ~1) | (1 if c else 0)
    @property
    def fz(self): return bool(self.f & 0x40)
    @property
    def fc(self): return bool(self.f & 1)

    def hl(self): return (self.h << 8) | self.l
    def de(self): return (self.d << 8) | self.e
    def bc(self): return (self.b << 8) | self.c
    def sethl(self, v): self.h, self.l = (v >> 8) & 0xFF, v & 0xFF
    def setde(self, v): self.d, self.e = (v >> 8) & 0xFF, v & 0xFF
    def setbc(self, v): self.b, self.c = (v >> 8) & 0xFF, v & 0xFF

    def getr(self, i):
        if i == 6: return self.m[self.hl()]
        return [self.b, self.c, self.d, self.e, self.h, self.l, None, self.a][i]
    def setr(self, i, v):
        v &= 0xFF
        if   i == 0: self.b = v
        elif i == 1: self.c = v
        elif i == 2: self.d = v
        elif i == 3: self.e = v
        elif i == 4: self.h = v
        elif i == 5: self.l = v
        elif i == 6: self.m[self.hl()] = v
        elif i == 7: self.a = v

    def fetch(self):
        v = self.m[self.pc]; self.pc = (self.pc + 1) & 0xFFFF; return v
    def fetch16(self):
        lo = self.fetch(); return lo | (self.fetch() << 8)

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.m[self.sp] = v & 0xFF
        self.m[(self.sp + 1) & 0xFFFF] = (v >> 8) & 0xFF
    def pop(self):
        v = self.m[self.sp] | (self.m[(self.sp + 1) & 0xFFFF] << 8)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def alu(self, op, v):
        a = self.a
        if   op == 0:  r = a + v;               self.setC(r > 0xFF);  self.a = r & 0xFF   # ADD
        elif op == 1:  r = a + v + self.fc;     self.setC(r > 0xFF);  self.a = r & 0xFF   # ADC
        elif op == 2:  r = a - v;               self.setC(r < 0);     self.a = r & 0xFF   # SUB
        elif op == 3:  r = a - v - self.fc;     self.setC(r < 0);     self.a = r & 0xFF   # SBC
        elif op == 4:  self.a = a & v;          self.setC(0)                              # AND
        elif op == 5:  self.a = a ^ v;          self.setC(0)                              # XOR
        elif op == 6:  self.a = a | v;          self.setC(0)                              # OR
        elif op == 7:  r = a - v;               self.setC(r < 0);     self.setZ(r); return  # CP
        self.setZ(self.a)

    def step(self):
        self.icount += 1
        op = self.fetch()

        if op == 0xF3: return                                      # DI
        if op == 0x00: return                                      # NOP
        if op == 0x76: raise Halt("HALT")
        if op == 0xD9:                                             # EXX
            self.b, self.b2 = self.b2, self.b
            self.c, self.c2 = self.c2, self.c
            self.d, self.d2 = self.d2, self.d
            self.e, self.e2 = self.e2, self.e
            self.h, self.h2 = self.h2, self.h
            self.l, self.l2 = self.l2, self.l
            return
        if 0x40 <= op <= 0x7F:                                     # LD r,r'
            self.setr((op >> 3) & 7, self.getr(op & 7)); return
        if 0x80 <= op <= 0xBF:                                     # ALU A,r
            self.alu((op >> 3) & 7, self.getr(op & 7)); return
        if op & 0xC7 == 0xC6:                                      # ALU A,n
            self.alu((op >> 3) & 7, self.fetch()); return
        if op & 0xC7 == 0x06:                                      # LD r,n
            self.setr((op >> 3) & 7, self.fetch()); return
        if op & 0xC7 == 0x04:                                      # INC r (C preserved)
            i = (op >> 3) & 7; v = (self.getr(i) + 1) & 0xFF
            self.setr(i, v); self.setZ(v); return
        if op & 0xC7 == 0x05:                                      # DEC r (C preserved)
            i = (op >> 3) & 7; v = (self.getr(i) - 1) & 0xFF
            self.setr(i, v); self.setZ(v); return
        if op in (0x01, 0x11, 0x21, 0x31):                         # LD rr,nn
            v = self.fetch16()
            [self.setbc, self.setde, self.sethl,
             lambda x: setattr(self, "sp", x)][(op >> 4)](v); return
        if op in (0x03, 0x13, 0x23, 0x33):                         # INC rr (no flags)
            g = [self.bc, self.de, self.hl, lambda: self.sp][(op >> 4)]
            s = [self.setbc, self.setde, self.sethl,
                 lambda x: setattr(self, "sp", x)][(op >> 4)]
            s((g() + 1) & 0xFFFF); return
        if op in (0x0B, 0x1B, 0x2B, 0x3B):                         # DEC rr (no flags)
            g = [self.bc, self.de, self.hl, lambda: self.sp][(op >> 4)]
            s = [self.setbc, self.setde, self.sethl,
                 lambda x: setattr(self, "sp", x)][(op >> 4)]
            s((g() - 1) & 0xFFFF); return
        if op in (0x09, 0x19, 0x29, 0x39):                         # ADD HL,rr (sets C)
            v = [self.bc(), self.de(), self.hl(), self.sp][(op >> 4)]
            r = self.hl() + v
            self.setC(r > 0xFFFF); self.sethl(r & 0xFFFF); return
        if op == 0x32: self.m[self.fetch16()] = self.a; return     # LD (nn),A
        if op == 0x3A: self.a = self.m[self.fetch16()]; return     # LD A,(nn)
        if op == 0x22:                                             # LD (nn),HL
            ad = self.fetch16(); self.m[ad] = self.l
            self.m[(ad + 1) & 0xFFFF] = self.h; return
        if op == 0x2A:                                             # LD HL,(nn)
            ad = self.fetch16(); self.l = self.m[ad]
            self.h = self.m[(ad + 1) & 0xFFFF]; return
        if op == 0x0A: self.a = self.m[self.bc()]; return          # LD A,(BC)
        if op == 0x1A: self.a = self.m[self.de()]; return          # LD A,(DE)
        if op == 0x02: self.m[self.bc()] = self.a; return          # LD (BC),A
        if op == 0x12: self.m[self.de()] = self.a; return          # LD (DE),A
        if op == 0x0F:                                             # RRCA
            c = self.a & 1
            self.a = ((self.a >> 1) | (c << 7)) & 0xFF
            self.setC(c); return
        if op == 0x07:                                             # RLCA
            c = (self.a >> 7) & 1
            self.a = ((self.a << 1) | c) & 0xFF
            self.setC(c); return
        if op == 0x17:                                             # RLA
            c = (self.a >> 7) & 1
            self.a = ((self.a << 1) | (1 if self.fc else 0)) & 0xFF
            self.setC(c); return
        if op == 0x1F:                                             # RRA
            c = self.a & 1
            self.a = ((self.a >> 1) | (0x80 if self.fc else 0)) & 0xFF
            self.setC(c); return
        if op == 0x18:                                             # JR e
            e = self.fetch(); self.pc = (self.pc + (e - 256 if e > 127 else e)) & 0xFFFF; return
        if op in (0x20, 0x28, 0x30, 0x38):                         # JR cc,e
            e = self.fetch()
            take = {0x20: not self.fz, 0x28: self.fz,
                    0x30: not self.fc, 0x38: self.fc}[op]
            if take: self.pc = (self.pc + (e - 256 if e > 127 else e)) & 0xFFFF
            return
        if op == 0x10:                                             # DJNZ
            e = self.fetch(); self.b = (self.b - 1) & 0xFF
            if self.b: self.pc = (self.pc + (e - 256 if e > 127 else e)) & 0xFFFF
            return
        if op == 0xC3: self.pc = self.fetch16(); return            # JP nn
        if op in (0xC2, 0xCA, 0xD2, 0xDA):                         # JP cc,nn
            ad = self.fetch16()
            take = {0xC2: not self.fz, 0xCA: self.fz,
                    0xD2: not self.fc, 0xDA: self.fc}[op]
            if take: self.pc = ad
            return
        if op in (0xC5, 0xD5, 0xE5):                               # PUSH rr
            self.push({0xC5: self.bc, 0xD5: self.de, 0xE5: self.hl}[op]()); return
        if op == 0xF5: self.push((self.a << 8) | self.f); return   # PUSH AF
        if op in (0xC1, 0xD1, 0xE1):                               # POP rr
            v = self.pop()
            {0xC1: self.setbc, 0xD1: self.setde, 0xE1: self.sethl}[op](v); return
        if op == 0xF1:                                             # POP AF
            v = self.pop(); self.a, self.f = (v >> 8) & 0xFF, v & 0xFF; return
        if op == 0xCD:                                             # CALL nn
            ad = self.fetch16(); self.push(self.pc); self.pc = ad; return
        if op == 0xC9: self.pc = self.pop(); return                # RET
        if op in (0xC4, 0xCC, 0xD4, 0xDC):                         # CALL cc,nn
            ad = self.fetch16()
            take = {0xC4: not self.fz, 0xCC: self.fz,
                    0xD4: not self.fc, 0xDC: self.fc}[op]
            if take: self.push(self.pc); self.pc = ad
            return
        if op in (0xC0, 0xC8, 0xD0, 0xD8):                         # RET cc
            take = {0xC0: not self.fz, 0xC8: self.fz,
                    0xD0: not self.fc, 0xD8: self.fc}[op]
            if take: self.pc = self.pop()
            return
        if op == 0xEB:                                             # EX DE,HL
            self.d, self.h = self.h, self.d
            self.e, self.l = self.l, self.e; return
        if op == 0xCB:                                             # CB prefix
            sub = self.fetch()
            if 0x38 <= sub <= 0x3F:                                # SRL r
                i = sub & 7; v = self.getr(i)
                self.setC(v & 1); v >>= 1
                self.setr(i, v); self.setZ(v); return
            if 0x18 <= sub <= 0x1F:                                # RR r
                i = sub & 7; v = self.getr(i)
                c = v & 1
                v = (v >> 1) | (0x80 if self.fc else 0)
                self.setC(c); self.setr(i, v); self.setZ(v); return
            if 0x28 <= sub <= 0x2F:                                # SRA r
                i = sub & 7; v = self.getr(i)
                c = v & 1
                v = (v >> 1) | (v & 0x80)
                self.setC(c); self.setr(i, v); self.setZ(v); return
            raise Halt(f"CB {sub:02X} unimplemented at {self.pc - 2:04X}")
        if op == 0xED:                                             # ED prefix
            sub = self.fetch()
            if sub & 0xCF == 0x4B:                                 # LD rr,(nn)
                ad = self.fetch16()
                v = self.m[ad] | (self.m[(ad + 1) & 0xFFFF] << 8)
                [self.setbc, self.setde, self.sethl,
                 lambda x: setattr(self, "sp", x)][(sub >> 4) & 3](v)
                return
            if sub & 0xCF == 0x43:                                 # LD (nn),rr
                ad = self.fetch16()
                v = [self.bc(), self.de(), self.hl(), self.sp][(sub >> 4) & 3]
                self.m[ad] = v & 0xFF
                self.m[(ad + 1) & 0xFFFF] = (v >> 8) & 0xFF
                return
            if sub & 0xCF == 0x42:                                 # SBC HL,rr
                v = [self.bc(), self.de(), self.hl(), self.sp][(sub >> 4) & 3]
                r = self.hl() - v - self.fc
                self.setC(r < 0); r &= 0xFFFF
                self.sethl(r); self.setZ(1 if r else 0)            # Z from 16-bit
                if r == 0: self.f |= 0x40
                else:      self.f &= ~0x40
                return
            raise Halt(f"ED {sub:02X} unimplemented at {self.pc - 2:04X}")
        raise Halt(f"opcode {op:02X} unimplemented at {self.pc - 1:04X}")

def main():
    frames = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    syms = load_syms()
    mem = bytearray(65536)
    code = open(os.path.join(ROOT, "build", "raycast.bin"), "rb").read()
    mem[LOAD:LOAD + len(code)] = code

    cpu = Z80(mem)
    cpu.pc = LOAD
    main_addr = syms["MAIN"]

    hits = 0
    limit = 20_000_000
    while cpu.icount < limit:
        if cpu.pc == main_addr:
            hits += 1
            if hits > frames:           # arrival N+1 = N complete frames
                break
        cpu.step()
    else:
        raise SystemExit("instruction limit hit — runaway?")

    vram = bytes(mem[0x7000:0x7800])
    open(os.path.join(ROOT, "build", "emu_vram.bin"), "wb").write(vram)

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import gen_tables                    # regenerates ref + gives us the png writer
    gen_tables.vram_to_png(vram, os.path.join(ROOT, "build", "emu.png"))

    ref = open(os.path.join(ROOT, "build", "ref_vram.bin"), "rb").read()
    diffs = [i for i in range(2048) if vram[i] != ref[i]]
    print(f"{cpu.icount} instructions, {hits - 1} frame(s) completed")
    if not diffs:
        print("VRAM MATCHES REFERENCE - byte-exact PASS")
    else:
        print(f"{len(diffs)} bytes differ; first 10:")
        for i in diffs[:10]:
            print(f"  vram[{i:4}] row={i//32:2} col={i%32:2}: emu={vram[i]:02X} ref={ref[i]:02X}")

if __name__ == "__main__":
    main()
