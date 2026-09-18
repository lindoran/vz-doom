; ============================================================================
; vzdoom_kiosk.asm — VZ-DOOM, kiosk/continuous-play variant
; ============================================================================
; Derived from vzdoom.asm (Milestone 4). vzdoom.asm is UNCHANGED by this
; file — this is a sibling build target, same convention as raycast.asm /
; walk.asm / wavedemo.asm. On top of the base game, this adds:
;
;   - Continuous play: dying no longer requires a full reload. Death shows
;     the title/controls screen; SPACE respawns the player and scatters up
;     to 3 demons across both rooms (zoned pick — one guaranteed per room,
;     third is a coin-flip — so placement isn't just biased toward whichever
;     room happens to have more open floor tiles).
;   - Wave clear: downing all 3 demons while still alive heals +20 HP
;     (capped at 100), plays a short fanfare, ramps demon step speed up a
;     notch every 2 waves (capped), and drops in a fresh wave — no death
;     required to keep playing.
;   - Title/controls screen: shown at boot and on every death. Drops to VZ
;     text mode (same VRAM base/stride as hi-res, just interpreted as
;     characters instead of pixels), prints name + controls, blocks on
;     SPACE, restores hi-res. No idle/attract timer — see note below.
;   - EXHIBIT build flag (EQU near the top): 1 = kiosk build, Q never drops
;     back to the loader (SPACE is the only way forward, from boot or
;     death). 0 = normal build, Q quits to the loader as in vzdoom.asm.
;     Ships here set to 1; flip to 0 and reassemble for a dev build.
;
; Hardware notes / open items for review:
;   - No bank switching, no SD-loader DOS calls anywhere in this file —
;     confirmed by grepping for OUT/port-$70/loader jump-table addresses.
;     Runs entirely in linear RAM from START to BANKEND (see the ASSERT
;     below), so it needs nothing beyond a stock VZ200/300 + 16K expansion:
;     that pack gives a contiguous 18K (0x7800-0xBFFF) which is the same
;     range this file already targets, no clone-specific 128K bank RAM
;     required.
;   - Frame-sync: WAITFS polls MMIO bit 7 (frame-sync flag) to line up
;     LATCH mode switches with a frame boundary before writing VRAM, since
;     an unsynced switch mid-scan produced visible tearing in testing.
;     It's a bounded poll (~1-2 frames' worth per phase), not an infinite
;     spin, so a flag that doesn't toggle as expected degrades to
;     "proceed anyway" instead of hanging. Interrupts are never enabled
;     anywhere in this file (DI at boot, no EI), so this is pure polling,
;     not IRQ-driven.
;   - Text-mode charset: bit 6 selects normal/inverse video for this
;     hardware's internal alpha glyph set, and plain ASCII uppercase
;     ($41-$5A) has that bit set while space/digits/punctuation don't —
;     so writing raw ASCII made letters render inverse. TXTCPY masks each
;     byte with $3F on the way into VRAM to fix that. Verified against
;     every string actually used (see INFOSCR). Glyph *shapes* are the
;     standard MC6847-family internal set; I don't have this project's
;     exact ROM in front of me to confirm identical wiring on all
;     variants, flagging for anyone testing on hardware I haven't seen.
;   - No idle/attract-mode timer. An earlier draft tried to time an idle
;     screen off frame counts and got the pacing wrong (no vsync/RTC to
;     calibrate against), so it's been dropped in favour of the simpler,
;     verifiable behaviour: title screen at boot and on every death, full
;     stop, nothing timer-driven.
;
; Controls: W/S move · A/D turn · ,/. strafe · E open door · SPACE fire
;           SPACE also dismisses the title screen / respawns after death
;
; Build:  ./build.sh src/vzdoom_kiosk.asm VZDOOMK   (Linux)
;         ..\build.ps1 src\vzdoom_kiosk.asm VZDOOMK (Windows, if adapted)
; ============================================================================

        DEVICE  NOSLOT64K

VRAM    EQU     $7000
LATCH   EQU     $6800

KROW0   EQU     $68FE
KROW1   EQU     $68FD
KROW4   EQU     $68EF

TURNSPD  EQU    2
DOORTIME EQU    75              ; auto-close delay in frames (~5s)
VIEWH    EQU    52              ; 3D view rows 0-51; rows 52-63 = HUD panel
HORIZON  EQU    26
GUNVRAM  EQU    VRAM + 36*32 + 14   ; gun bottom sits on view row 51
HUDVRAM  EQU    VRAM + 52*32

; ---- build config -----------------------------------------------------------
; EXHIBIT=1: kiosk/display build. Q never drops back to the loader, neither
;            during live play nor on the death screen — SPACE is the only
;            way forward, and it always respawns. Good for an unattended
;            exhibit where a stray keypress shouldn't end up at a DOS prompt.
; EXHIBIT=0: normal build. Q quits to the loader as before.
EXHIBIT  EQU    1

        ORG     $7AE9

START:
        DI
        LD      SP, $8FFE

        LD      A, %00001000    ; Mode 1, CSS=0, speaker off
        LD      (LATCH), A

        LD      A, R            ; seed the respawn RNG once, from refresh reg
        OR      1               ; (must stay non-zero for the LFSR to run)
        LD      (RNGST), A

        CALL    INFOSCR         ; title/controls screen; blocks until SPACE
        CALL    INITPLR

; ----------------------------------------------------------------------------
MAIN:
        CALL    RNGTICK         ; keep the respawn RNG mixing every frame

        ; ---- input ----
        XOR     A
        LD      (MOVED), A

        IF EXHIBIT=0
        LD      A, (KROW0)
        AND     $10             ; Q = quit: text mode, cold restart to loader
        JR      NZ, .noq
        XOR     A
        LD      (LATCH), A
        JP      0
.noq:
        ENDIF
        LD      A, (KROW0)
        AND     $02             ; W
        CALL    Z, MOVEF
        LD      A, (KROW1)
        AND     $02             ; S
        CALL    Z, MOVEB
        LD      A, (KROW1)
        AND     $10             ; A
        CALL    Z, TURNL
        LD      A, (KROW1)
        AND     $08             ; D
        CALL    Z, TURNR
        LD      A, (KROW4)
        AND     $08             ; ,
        CALL    Z, STRAFL
        LD      A, (KROW4)
        AND     $02             ; .
        CALL    Z, STRAFR
        LD      A, (KROW0)
        AND     $08             ; E
        CALL    Z, DOOROP
        LD      A, (KROW4)
        AND     $10             ; SPACE
        CALL    Z, FIRE

        ; ---- footstep: every 8th frame in which we actually moved ----
        LD      A, (MOVED)
        OR      A
        JR      Z, .nostep
        LD      A, (STEPC)
        INC     A
        LD      (STEPC), A
        AND     7
        JR      NZ, .nostep
        LD      D, 20           ; short click
        LD      B, 2
        CALL    BEEP
.nostep:

        ; ---- timers ----
        LD      A, (FLASH)
        OR      A
        JR      Z, .nf
        DEC     A
        LD      (FLASH), A
.nf:    LD      A, (FIRECD)
        OR      A
        JR      Z, .nc
        DEC     A
        LD      (FIRECD), A
.nc:
        ; ---- door auto-close ----
        LD      A, (DOORT)
        OR      A
        JR      Z, .nd
        DEC     A
        LD      (DOORT), A
        JR      NZ, .nd
        ; timer expired: is the player standing in the door cell?
        LD      A, (PXV+1)
        AND     $0F
        LD      C, A
        LD      A, (PYV+1)
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      E, A            ; E = player cell index
        LD      A, (DOORC)
        CP      E
        JR      NZ, .close
        LD      A, 1            ; occupied — try again next frame
        LD      (DOORT), A
        JR      .nd
.close: LD      C, A
        LD      B, HIGH MAP
        LD      A, 2
        LD      (BC), A         ; door shuts
        LD      D, 180          ; low thunk behind you
        LD      B, 8
        CALL    BEEP
.nd:
        ; ---- enemy AI: one demon steps every frame, round-robin, pause 4th ----
        LD      A, (FCNT)
        INC     A
        LD      (FCNT), A
        AND     3
        CP      3
        JR      Z, .noai
        LD      (EIDX), A
        CALL    AIMOVE
.noai:
        CALL    DODMG           ; demon bites, pain timers
        CALL    HUDUPD          ; face/pips/tally, redrawn only on change

        ; ---- wave clear: all 3 demons down -> small heal + fresh wave -------
        LD      A, (ENALIV+0)
        LD      B, A
        LD      A, (ENALIV+1)
        OR      B
        LD      B, A
        LD      A, (ENALIV+2)
        OR      B
        JR      NZ, .noclear    ; someone's still up -> nothing to do
        CALL    WAVECLR
.noclear:
        LD      A, (HLTH)
        OR      A
        JR      NZ, .living
.dead:  CALL    INFOSCR         ; controls screen; blocks until SPACE (or Q, if EXHIBIT=0)
        CALL    RESPAWN
        JP      MAIN
.living:

        ; ---- render frame (M2/M3 raycaster, doors added at HIT) ----
        XOR     A
        LD      (COLV), A

COL:
        LD      A, (COLV)
        ADD     A, A
        LD      E, A
        LD      A, (PANGV)
        ADD     A, 31
        SUB     E

        LD      L, A
        LD      H, HIGH STEPXL
        LD      E, (HL)
        INC     H
        LD      D, (HL)
        INC     H
        LD      A, (HL)
        INC     H
        LD      H, (HL)
        LD      L, A
        PUSH    HL
        EXX
        POP     DE
        LD      HL, (PYV)
        LD      B, 0
        EXX
        LD      HL, (PXV)
        LD      B, HIGH MAP

RSTEP:
        ADD     HL, DE
        LD      A, H
        AND     $0F
        LD      C, A
        EXX
        ADD     HL, DE
        LD      A, H
        INC     B
        EXX
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      C, A
        LD      A, (BC)
        OR      A
        JR      Z, RSTEP

        ; ---- cell type: door renders $DD on both faces ----
        CP      2
        JR      NZ, .solid
        LD      A, $DD
        JR      .face
.solid: LD      A, H
        AND     $0F
        LD      C, A
        OR      A
        SBC     HL, DE
        LD      A, H
        AND     $0F
        CP      C
        LD      A, $FF
        JR      Z, .face
        LD      A, $AA
.face:  LD      (WALLB), A

        EXX
        LD      A, B
        EXX
        LD      D, A
        LD      A, (COLV)
        LD      L, A
        LD      H, HIGH FISH
        LD      E, (HL)
        LD      A, D
        LD      D, 0
        LD      HL, 0
        LD      B, 8
.mul:   ADD     HL, HL
        ADD     A, A
        JR      NC, .ms
        ADD     HL, DE
.ms:    DJNZ    .mul

        LD      C, H            ; C = corrected distance for this column
        LD      A, (COLV)
        LD      L, A
        LD      H, HIGH DBUF
        LD      (HL), C         ; depth buffer — sprites test against this

        LD      L, C
        LD      H, HIGH HLUT
        LD      A, (HL)
        LD      (WALLN), A
        LD      B, A
        LD      A, VIEWH
        SUB     B
        SRL     A
        LD      (CEILN), A

        LD      A, (COLV)
        LD      L, A
        LD      H, HIGH VRAM
        LD      DE, 32

        LD      A, (CEILN)
        OR      A
        JR      Z, .wall
        LD      B, A
        XOR     A
.cl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .cl

.wall:  LD      A, (WALLN)
        LD      B, A
        LD      A, (WALLB)
.wl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .wl

        LD      A, (CEILN)
        OR      A
        JR      Z, .cnext
        LD      B, A
        LD      A, $55
.fl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .fl

.cnext: LD      A, (COLV)
        INC     A
        LD      (COLV), A
        CP      32
        JP      NZ, COL

        CALL    ENEMIES
        CALL    DRAWGUN
        JP      MAIN

; ----------------------------------------------------------------------------
; Weapon overlay: masked 4x16-byte blit, (mask,data) pairs column-major
; ----------------------------------------------------------------------------
DRAWGUN:
        LD      HL, GUNSPR
        LD      A, (FLASH)
        OR      A
        JR      Z, .norm
        LD      HL, FLSSPR
.norm:  LD      (GPTR), HL
        LD      HL, GUNVRAM
        LD      (VPTR), HL
        LD      A, 4
        LD      (GCOL), A
.gcol:  LD      A, 16
        LD      (GROW), A
.grow:  LD      HL, (GPTR)
        LD      C, (HL)         ; mask
        INC     HL
        LD      B, (HL)         ; data
        INC     HL
        LD      (GPTR), HL
        LD      HL, (VPTR)
        LD      A, (HL)
        AND     C
        OR      B
        LD      (HL), A
        LD      DE, 32
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GROW)
        DEC     A
        LD      (GROW), A
        JR      NZ, .grow
        ; next sprite column: back up 16 rows, right 1 byte
        LD      HL, (VPTR)
        LD      DE, -(16*32) + 1
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GCOL)
        DEC     A
        LD      (GCOL), A
        JR      NZ, .gcol
        RET

; ----------------------------------------------------------------------------
; Door open: probe the cell ~0.5 cell ahead; if it's a door, open it
; ----------------------------------------------------------------------------
DOOROP:
        LD      A, (PANGV)
        CALL    GETSTP          ; DE = dx, HL = dy (1/8 cell)
        ADD     HL, HL
        ADD     HL, HL          ; dy * 4 = half a cell
        PUSH    HL
        EX      DE, HL
        ADD     HL, HL
        ADD     HL, HL          ; dx * 4
        LD      DE, (PXV)
        ADD     HL, DE          ; probe X
        LD      A, H
        AND     $0F
        LD      C, A
        POP     HL
        LD      DE, (PYV)
        ADD     HL, DE          ; probe Y
        LD      A, H
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      C, A
        LD      B, HIGH MAP
        LD      A, (BC)
        CP      2
        RET     NZ              ; not a (closed) door
        XOR     A
        LD      (BC), A         ; open
        LD      A, C
        LD      (DOORC), A
        LD      A, DOORTIME
        LD      (DOORT), A
        LD      D, 25           ; door whoosh: falling sweep 2.8kHz -> 560Hz
        LD      E, 200
        LD      C, 3
        JP      SWEEP

; ----------------------------------------------------------------------------
FIRE:
        LD      A, (FIRECD)
        OR      A
        RET     NZ
        LD      A, 4
        LD      (FLASH), A
        LD      A, 10
        LD      (FIRECD), A
        LD      D, 12           ; fire: fast falling zap
        LD      E, 90
        LD      C, 4
        CALL    SWEEP
        JP      FIREHIT         ; hitscan vs last frame's enemy projections

; ----------------------------------------------------------------------------
; BEEP: square wave on speaker (latch bits 0/5), D = half-period, B = cycles.
; Keeps bit3 (Mode 1) set so the display never glitches.
; ----------------------------------------------------------------------------
BEEP:
        LD      A, %00001001    ; speaker+, mode 1
        LD      (LATCH), A
        CALL    SDLY
        LD      A, %00101000    ; speaker-, mode 1
        LD      (LATCH), A
        CALL    SDLY
        DJNZ    BEEP
        LD      A, %00001000    ; speaker off, mode 1
        LD      (LATCH), A
        RET
SDLY:   LD      A, D
.sd:    DEC     A
        JR      NZ, .sd
        RET

; ----------------------------------------------------------------------------
; SWEEP: falling-pitch square wave. D = start half-period, E = end,
; C = increment per cycle. Larger D = lower pitch, so D grows toward E.
; ----------------------------------------------------------------------------
SWEEP:
.cyc:   LD      A, %00001001
        LD      (LATCH), A
        CALL    SDLY
        LD      A, %00101000
        LD      (LATCH), A
        CALL    SDLY
        LD      A, D
        ADD     A, C
        LD      D, A
        CP      E
        JR      C, .cyc
        LD      A, %00001000
        LD      (LATCH), A
        RET

; ----------------------------------------------------------------------------
; Movement (M3, verified) — TRYX/TRYY also set MOVED for the footstep sound
; ----------------------------------------------------------------------------
GETSTP: LD      L, A
        LD      H, HIGH STEPXL
        LD      E, (HL)
        INC     H
        LD      D, (HL)
        INC     H
        LD      A, (HL)
        INC     H
        LD      H, (HL)
        LD      L, A
        RET

NEGDE:  XOR     A
        SUB     E
        LD      E, A
        SBC     A, A
        SUB     D
        LD      D, A
        RET

MOVEF:  LD      A, (PANGV)
        JR      MVCOM
STRAFL: LD      A, (PANGV)
        ADD     A, 64
        JR      MVCOM
STRAFR: LD      A, (PANGV)
        SUB     64
MVCOM:  CALL    GETSTP
        PUSH    HL
        CALL    TRYX
        POP     DE
        JP      TRYY

MOVEB:  LD      A, (PANGV)
        CALL    GETSTP
        CALL    NEGDE
        PUSH    HL
        CALL    TRYX
        POP     DE
        CALL    NEGDE
        JP      TRYY

TURNL:  LD      A, (PANGV)
        ADD     A, TURNSPD
        LD      (PANGV), A
        RET

TURNR:  LD      A, (PANGV)
        SUB     TURNSPD
        LD      (PANGV), A
        RET

TRYX:   LD      HL, (PXV)
        ADD     HL, DE
        LD      A, H
        AND     $0F
        LD      C, A
        LD      A, (PYV+1)
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      C, A
        LD      B, HIGH MAP
        LD      A, (BC)
        OR      A
        RET     NZ
        LD      (PXV), HL
        LD      A, 1
        LD      (MOVED), A
        RET

TRYY:   LD      HL, (PYV)
        ADD     HL, DE
        LD      A, H
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        LD      E, A
        LD      A, (PXV+1)
        AND     $0F
        OR      E
        LD      C, A
        LD      B, HIGH MAP
        LD      A, (BC)
        OR      A
        RET     NZ
        LD      (PYV), HL
        LD      A, 1
        LD      (MOVED), A
        RET

; ============================================================================
; M5 — enemies
; ============================================================================

; ---- per-frame enemy pass: project all, then draw far-to-near ---------------
ENEMIES:
        XOR     A
        LD      (EIDX), A
.p1:    CALL    EPROJ
        LD      A, (EIDX)
        INC     A
        LD      (EIDX), A
        CP      3
        JR      NZ, .p1

        XOR     A
        LD      (EDRAWN+0), A
        LD      (EDRAWN+1), A
        LD      (EDRAWN+2), A

.pick:  ; select undrawn on-screen enemy with the LARGEST corr (strict >,
        ; scanning 0..2 — ties go to the lowest index; the reference mirrors this)
        LD      A, 255
        LD      (BESTI), A
        XOR     A
        LD      (BESTC), A

        LD      A, (EDRAWN+0)
        OR      A
        JR      NZ, .c1
        LD      A, (ECOLA+0)
        CP      100
        JR      Z, .c1
        LD      A, (ECORRA+0)
        LD      E, A
        LD      A, (BESTI)
        CP      255
        JR      Z, .t0
        LD      A, (BESTC)
        CP      E
        JR      NC, .c1
.t0:    LD      A, E
        LD      (BESTC), A
        XOR     A
        LD      (BESTI), A
.c1:
        LD      A, (EDRAWN+1)
        OR      A
        JR      NZ, .c2
        LD      A, (ECOLA+1)
        CP      100
        JR      Z, .c2
        LD      A, (ECORRA+1)
        LD      E, A
        LD      A, (BESTI)
        CP      255
        JR      Z, .t1
        LD      A, (BESTC)
        CP      E
        JR      NC, .c2
.t1:    LD      A, E
        LD      (BESTC), A
        LD      A, 1
        LD      (BESTI), A
.c2:
        LD      A, (EDRAWN+2)
        OR      A
        JR      NZ, .c3
        LD      A, (ECOLA+2)
        CP      100
        JR      Z, .c3
        LD      A, (ECORRA+2)
        LD      E, A
        LD      A, (BESTI)
        CP      255
        JR      Z, .t2
        LD      A, (BESTC)
        CP      E
        JR      NC, .c3
.t2:    LD      A, E
        LD      (BESTC), A
        LD      A, 2
        LD      (BESTI), A
.c3:
        LD      A, (BESTI)
        CP      255
        RET     Z               ; nothing left to draw
        LD      (EIDX), A
        LD      E, A
        LD      D, 0
        LD      HL, EDRAWN
        ADD     HL, DE
        LD      (HL), 1
        CALL    DRAWDEMON
        JP      .pick

; ---- project enemy EIDX -> ECOLA/ECORRA (255,255 = dead/offscreen) ----------
EPROJ:
        CALL    ELOAD
        OR      A
        JR      Z, .off
        LD      HL, (WEX)
        LD      DE, (PXV)
        OR      A
        SBC     HL, DE
        LD      (DXV), HL
        LD      A, H
        OR      L
        LD      C, A            ; C != 0 if dx != 0
        LD      HL, (WEY)
        LD      DE, (PYV)
        OR      A
        SBC     HL, DE
        LD      (DYV), HL
        LD      A, H
        OR      L
        OR      C
        JR      Z, .off         ; enemy exactly on the player
        CALL    ANGDIST         ; A = angle, (DIST8) set
        LD      E, A
        LD      A, (PANGV)
        ADD     A, 31
        SUB     E               ; rel: accept < 96 or >= 224 (~+/-90 deg)
        CP      96
        JR      C, .on
        CP      224
        JR      C, .off
.on:    SRA     A               ; SIGNED column, -16..47 — edge sprites get
        LD      (WCOL), A       ; clipped per-column instead of popping out
        LD      E, A
        AND     $80             ; clamp FISH index to 0..31
        JR      Z, .fpos
        XOR     A
        JR      .fidx
.fpos:  LD      A, E
        CP      32
        JR      C, .fidx
        LD      A, 31
.fidx:  LD      L, A
        LD      H, HIGH FISH
        LD      E, (HL)
        LD      D, 0
        LD      A, (DIST8)
        LD      HL, 0
        LD      B, 8
.mul:   ADD     HL, HL
        ADD     A, A
        JR      NC, .ms
        ADD     HL, DE
.ms:    DJNZ    .mul
        LD      C, H            ; C = corr
        LD      A, (EIDX)
        LD      E, A
        LD      D, 0
        LD      HL, ECORRA
        ADD     HL, DE
        LD      (HL), C
        LD      HL, ECOLA
        ADD     HL, DE
        LD      A, (WCOL)
        LD      (HL), A
        RET
.off:   LD      A, (EIDX)
        LD      E, A
        LD      D, 0
        LD      HL, ECOLA
        ADD     HL, DE
        LD      (HL), 100       ; offscreen sentinel (100 is outside -16..47)
        LD      HL, ECORRA
        ADD     HL, DE
        LD      (HL), 255
        RET

; ---- octant atan2 + octagonal distance --------------------------------------
; in: (DXV),(DYV) signed 8.8 deltas (not both zero)
; out: A = angle (256/rev, 0=+X, 64=+Y), (DIST8) = distance in 1/8-cell units
ANGDIST:
        LD      HL, (DXV)
        LD      A, H
        AND     $80
        LD      (SXF), A
        JR      Z, .xp
        XOR     A
        SUB     L
        LD      L, A
        LD      A, 0
        SBC     A, H
        LD      H, A
.xp:    LD      (ADXV), HL
        LD      HL, (DYV)
        LD      A, H
        AND     $80
        LD      (SYF), A
        JR      Z, .yp
        XOR     A
        SUB     L
        LD      L, A
        LD      A, 0
        SBC     A, H
        LD      H, A
.yp:    LD      (ADYV), HL

        LD      HL, (ADXV)
        LD      DE, (ADYV)
        OR      A
        SBC     HL, DE
        JR      C, .swap
        XOR     A
        LD      (SWF), A
        LD      HL, (ADXV)
        LD      (MXV), HL
        LD      HL, (ADYV)
        LD      (MNV), HL
        JR      .dist
.swap:  LD      A, 1
        LD      (SWF), A
        LD      HL, (ADYV)
        LD      (MXV), HL
        LD      HL, (ADXV)
        LD      (MNV), HL

.dist:  ; DIST8 = (MX + MN/2) >> 5, clamped to 255
        LD      HL, (MNV)
        SRL     H
        RR      L
        LD      DE, (MXV)
        ADD     HL, DE
        SRL     H
        RR      L
        SRL     H
        RR      L
        SRL     H
        RR      L
        SRL     H
        RR      L
        SRL     H
        RR      L
        LD      A, H
        OR      A
        JR      Z, .d8
        LD      L, 255
.d8:    LD      A, L
        LD      (DIST8), A

        ; normalise MX (and MN with it) to 8 bits for the divide
.norm:  LD      A, (MXV+1)
        OR      A
        JR      Z, .div
        LD      HL, (MXV)
        SRL     H
        RR      L
        LD      (MXV), HL
        LD      HL, (MNV)
        SRL     H
        RR      L
        LD      (MNV), HL
        JR      .norm

.div:   ; ratio = (MN << 5) / MX  (0..32), restoring division
        LD      HL, (MNV)
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        LD      A, (MXV)
        LD      C, A
        XOR     A
        LD      B, 16
.dv:    ADD     HL, HL
        RLA
        JR      C, .fs          ; 9th remainder bit set: subtract wraps mod 256
        CP      C
        JR      C, .dn
.fs:    SUB     C
        INC     L
.dn:    DJNZ    .dv

        ; base = ATAN5[ratio]; fold octants
        LD      A, L
        LD      HL, ATAN5
        LD      E, A
        LD      D, 0
        ADD     HL, DE
        LD      A, (HL)
        LD      E, A            ; E = base angle 0..32
        LD      A, (SWF)
        OR      A
        JR      NZ, .ydom
        LD      A, (SXF)
        OR      A
        JR      NZ, .xneg
        LD      A, (SYF)
        OR      A
        LD      A, E
        RET     Z               ; +x +y: base
        XOR     A               ; +x -y: -base
        SUB     E
        RET
.xneg:  LD      A, (SYF)
        OR      A
        JR      NZ, .q3
        LD      A, 128          ; -x +y: 128-base
        SUB     E
        RET
.q3:    LD      A, 128          ; -x -y: 128+base
        ADD     A, E
        RET
.ydom:  LD      A, (SYF)
        OR      A
        JR      NZ, .yneg
        LD      A, (SXF)
        OR      A
        JR      NZ, .q2b
        LD      A, 64           ; +x big+y: 64-base
        SUB     E
        RET
.q2b:   LD      A, 64           ; -x big+y: 64+base
        ADD     A, E
        RET
.yneg:  LD      A, (SXF)
        OR      A
        JR      NZ, .q4b
        LD      A, 192          ; +x big-y: 192+base
        ADD     A, E
        RET
.q4b:   LD      A, 192          ; -x big-y: 192-base
        SUB     E
        RET

; ---- draw demon EIDX: banded size, floor-grounded, depth-tested -------------
DRAWDEMON:
        LD      A, (EIDX)
        LD      E, A
        LD      D, 0
        LD      HL, ECORRA
        ADD     HL, DE
        LD      A, (HL)
        LD      (WCORR), A
        ; occlusion depth = corr - corr/8: the octagonal distance approx
        ; overestimates up to ~12%; without this, wall-adjacent demons flicker
        LD      E, A
        SRL     A
        SRL     A
        SRL     A
        LD      C, A
        LD      A, E
        SUB     C
        LD      (WCOCC), A
        LD      A, (EIDX)
        LD      E, A
        LD      D, 0
        LD      HL, ECOLA
        ADD     HL, DE
        LD      A, (HL)
        LD      (WCOL), A

        LD      A, (WCORR)
        CP      20
        JR      NC, .notL
        LD      HL, DEMON_L
        LD      A, 6
        LD      (SPW), A
        LD      A, 24
        LD      (SPH), A
        JR      .geom
.notL:  CP      40
        JR      NC, .notM
        LD      HL, DEMON_M
        LD      A, 4
        LD      (SPW), A
        LD      A, 16
        LD      (SPH), A
        JR      .geom
.notM:  LD      HL, DEMON_S
        LD      A, 2
        LD      (SPW), A
        LD      A, 8
        LD      (SPH), A
.geom:  LD      (STAB), HL

        ; top = 32 + HLUT[corr]/2 - height   (never clips: bands guarantee it)
        LD      A, (WCORR)
        LD      L, A
        LD      H, HIGH HLUT
        LD      A, (HL)
        SRL     A
        ADD     A, HORIZON
        LD      C, A
        LD      A, (SPH)
        LD      E, A
        LD      A, C
        SUB     E
        LD      (STOPR), A

        ; leftmost screen column
        LD      A, (SPW)
        SRL     A
        LD      E, A
        LD      A, (WCOL)
        SUB     E
        LD      (SCST), A

        XOR     A
        LD      (SCC), A
.cloop: LD      A, (SCC)
        LD      E, A
        LD      A, (SCST)
        ADD     A, E
        CP      32              ; unsigned: rejects wrapped negatives too
        JR      NC, .next
        LD      (SCA), A

        ; wall depth test: draw only if deflated corr < DBUF[col]
        LD      L, A
        LD      H, HIGH DBUF
        LD      E, (HL)
        LD      A, (WCOCC)
        CP      E
        JR      NC, .next

        ; GPTR = STAB + SCC * SPH * 2
        LD      A, (SPH)
        ADD     A, A
        LD      E, A
        LD      D, 0
        LD      HL, (STAB)
        LD      A, (SCC)
        OR      A
        JR      Z, .gp
.gm:    ADD     HL, DE
        DEC     A
        JR      NZ, .gm
.gp:    LD      (GPTR), HL

        ; VPTR = VRAM + STOPR*32 + SCA
        LD      A, (STOPR)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        LD      A, (SCA)
        OR      L
        LD      L, A
        LD      A, H
        OR      HIGH VRAM
        LD      H, A
        LD      (VPTR), HL

        LD      A, (SPH)
        LD      (GROW), A
.rloop: LD      HL, (GPTR)
        LD      C, (HL)
        INC     HL
        LD      B, (HL)
        INC     HL
        LD      (GPTR), HL
        LD      HL, (VPTR)
        LD      A, (HL)
        AND     C
        OR      B
        LD      (HL), A
        LD      DE, 32
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GROW)
        DEC     A
        LD      (GROW), A
        JR      NZ, .rloop

.next:  LD      A, (SCC)
        INC     A
        LD      (SCC), A
        LD      E, A
        LD      A, (SPW)
        CP      E
        JR      NZ, .cloop
        RET

; ---- chase AI: enemy EIDX steps 1/8 cell toward the player per axis ---------
; standoff: no step while |delta| < 96 (0.375 cell). Doors block (cell != 0).
AIMOVE:
        CALL    ELOAD
        OR      A
        RET     Z
        LD      HL, (PXV)
        LD      DE, (WEX)
        OR      A
        SBC     HL, DE
        CALL    AISTEP
        LD      A, D
        OR      E
        JR      Z, .xno
        LD      HL, (WEX)
        ADD     HL, DE
        LD      A, H
        AND     $0F
        LD      C, A
        LD      A, (WEY+1)
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      C, A
        LD      B, HIGH MAP
        LD      A, (BC)
        OR      A
        JR      NZ, .xno
        CALL    OCCUP           ; another demon in that cell? (C = cell idx)
        JR      NZ, .xno
        LD      (WEX), HL
.xno:   LD      HL, (PYV)
        LD      DE, (WEY)
        OR      A
        SBC     HL, DE
        CALL    AISTEP
        LD      A, D
        OR      E
        JR      Z, .yno
        LD      HL, (WEY)
        ADD     HL, DE
        LD      A, H
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        LD      E, A
        LD      A, (WEX+1)
        AND     $0F
        OR      E
        LD      C, A
        LD      B, HIGH MAP
        LD      A, (BC)
        OR      A
        JR      NZ, .yno
        CALL    OCCUP
        JR      NZ, .yno
        LD      (WEY), HL
.yno:   JP      ESTORE

; C = candidate cell index. NZ if a DIFFERENT alive demon occupies that cell.
; Preserves HL (the candidate position) and B.
OCCUP:  PUSH    HL
        LD      A, C
        LD      (CANDC), A
        XOR     A
        LD      (OJDX), A
.lp:    LD      A, (OJDX)
        LD      E, A
        LD      A, (EIDX)
        CP      E
        JR      Z, .nx
        LD      D, 0
        LD      HL, ENALIV
        ADD     HL, DE
        LD      A, (HL)
        OR      A
        JR      Z, .nx
        LD      A, E
        ADD     A, A
        LD      E, A
        LD      HL, ENEMX+1
        ADD     HL, DE
        LD      A, (HL)
        AND     $0F
        LD      C, A
        LD      HL, ENEMY+1
        ADD     HL, DE
        LD      A, (HL)
        AND     $0F
        RRCA
        RRCA
        RRCA
        RRCA
        OR      C
        LD      C, A
        LD      A, (CANDC)
        CP      C
        JR      Z, .occ
.nx:    LD      A, (OJDX)
        INC     A
        LD      (OJDX), A
        CP      3
        JR      NZ, .lp
        POP     HL
        XOR     A               ; Z: cell is free
        RET
.occ:   POP     HL
        LD      A, 1
        OR      A               ; NZ: occupied
        RET

; HL = signed delta -> DE = +32 / -32 / 0 (step if |delta| >= 96)
AISTEP:
        LD      A, H
        AND     $80
        JR      NZ, .neg
        LD      DE, 96
        OR      A
        SBC     HL, DE
        JR      C, .zero
        LD      A, (AISTEPSZ)
        LD      E, A
        XOR     A
        LD      D, A            ; DE = +AISTEPSZ
        RET
.neg:   XOR     A
        SUB     L
        LD      L, A
        LD      A, 0
        SBC     A, H
        LD      H, A
        LD      DE, 96
        OR      A
        SBC     HL, DE
        JR      C, .zero
        LD      A, (AISTEPSZ)
        NEG
        LD      E, A
        LD      D, $FF          ; DE = -AISTEPSZ (sign-extended, fits since <128)
        RET
.zero:  LD      DE, 0
        RET

; ---- demon bites: any alive demon within 160 units on both axes -------------
DODMG:
        LD      A, (BITET)
        OR      A
        JR      Z, .chk
        DEC     A
        LD      (BITET), A
        JR      .fct
.chk:   XOR     A
        LD      (EIDX), A
.dl:    CALL    ELOAD
        OR      A
        JR      Z, .dn
        LD      HL, (PXV)
        LD      DE, (WEX)
        OR      A
        SBC     HL, DE
        CALL    ABSHL
        LD      DE, 160
        OR      A
        SBC     HL, DE
        JR      NC, .dn
        LD      HL, (PYV)
        LD      DE, (WEY)
        OR      A
        SBC     HL, DE
        CALL    ABSHL
        LD      DE, 160
        OR      A
        SBC     HL, DE
        JR      NC, .dn
        ; chomp
        LD      A, (HLTH)
        SUB     8
        JR      NC, .hp
        XOR     A
.hp:    LD      (HLTH), A
        LD      A, 12
        LD      (BITET), A
        LD      A, 6
        LD      (FACET), A
        LD      D, 220          ; pain buzz
        LD      B, 5
        CALL    BEEP
        JR      .fct
.dn:    LD      A, (EIDX)
        INC     A
        LD      (EIDX), A
        CP      3
        JR      NZ, .dl
.fct:   LD      A, (FACET)
        OR      A
        RET     Z
        DEC     A
        LD      (FACET), A
        RET

ABSHL:  LD      A, H            ; HL = |HL|
        AND     $80
        RET     Z
        XOR     A
        SUB     L
        LD      L, A
        LD      A, 0
        SBC     A, H
        LD      H, A
        RET

; ---- HUD state: face selection, kill count, dirty check ---------------------
HUDUPD:
        LD      A, (EYET)       ; eye-glance clock ticks every frame
        INC     A
        LD      (EYET), A
        LD      A, (HLTH)
        OR      A
        JR      NZ, .alive
        LD      A, 4            ; dead face
        JR      .st
.alive: LD      A, (FACET)
        OR      A
        JR      Z, .byhp
        LD      A, 3            ; ouch face
        JR      .st
.byhp:  LD      A, (HLTH)
        CP      67
        JR      C, .n1
        LD      A, (EYET)       ; healthy: Doomguy checks his flanks
        SRL     A
        SRL     A
        SRL     A
        AND     15
        LD      E, A
        LD      D, 0
        LD      HL, EYESEQ
        ADD     HL, DE
        LD      A, (HL)
        JR      .st
.n1:    CP      34
        JR      C, .n2
        LD      A, 1
        JR      .st
.n2:    LD      A, 2
.st:    LD      (FSTATE), A
        ; kills = 3 - alive
        LD      A, (ENALIV+0)
        LD      E, A
        LD      A, (ENALIV+1)
        ADD     A, E
        LD      E, A
        LD      A, (ENALIV+2)
        ADD     A, E
        LD      E, A            ; E = alive count
        LD      A, 3
        SUB     E
        LD      (KILLS), A
        ; redraw only when (health, kills, face) changed
        LD      A, (HLTH)
        LD      E, A
        LD      A, (LHLTH)
        CP      E
        JR      NZ, HUDDRW
        LD      A, (KILLS)
        LD      E, A
        LD      A, (LKILL)
        CP      E
        JR      NZ, HUDDRW
        LD      A, (FSTATE)
        LD      E, A
        LD      A, (LFACE)
        CP      E
        RET     Z

; ---- HUD draw: panel, face, 5 health pips, 3-icon kill tally ---------------
HUDDRW:
        LD      A, (HLTH)
        LD      (LHLTH), A
        LD      A, (KILLS)
        LD      (LKILL), A
        LD      A, (FSTATE)
        LD      (LFACE), A

        ; panel: 384 bytes of solid blue
        LD      HL, HUDVRAM
        LD      B, 192
.pf:    LD      (HL), $AA
        INC     HL
        LD      (HL), $AA
        INC     HL
        DJNZ    .pf

        ; face: 48-byte table at FACE0 + FSTATE*48, col-major 4x12
        LD      A, (FSTATE)
        LD      L, A
        LD      H, 0
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL
        ADD     HL, HL          ; *16
        LD      E, L
        LD      D, H
        ADD     HL, HL          ; *32
        ADD     HL, DE          ; *48
        LD      DE, FACE0
        ADD     HL, DE
        LD      (GPTR), HL
        LD      HL, HUDVRAM + 14
        LD      (VPTR), HL
        LD      A, 4
        LD      (GCOL), A
.fc:    LD      A, 12
        LD      (GROW), A
.fr:    LD      HL, (GPTR)
        LD      A, (HL)
        INC     HL
        LD      (GPTR), HL
        LD      HL, (VPTR)
        LD      (HL), A
        LD      DE, 32
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GROW)
        DEC     A
        LD      (GROW), A
        JR      NZ, .fr
        LD      HL, (VPTR)
        LD      DE, -(12*32) + 1
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GCOL)
        DEC     A
        LD      (GCOL), A
        JR      NZ, .fc

        ; pips: byte cols 2,4,6,8,10, rows 55-60; pip i full iff HLTH > i*20
        XOR     A
        LD      (SCC), A        ; pip index
.pl:    LD      A, (SCC)
        ADD     A, A            ; *2 -> byte col offset
        ADD     A, 2
        LD      L, A
        LD      H, 0
        LD      DE, VRAM + 55*32
        ADD     HL, DE
        ; threshold = pip * 20
        LD      A, (SCC)
        ADD     A, A
        ADD     A, A
        LD      E, A            ; *4
        ADD     A, A            ; *8
        ADD     A, A            ; *16
        ADD     A, E            ; *20
        LD      E, A
        LD      A, (HLTH)
        SUB     E
        LD      A, $FF          ; full pip: red
        JR      Z, .emp
        JR      NC, .val
.emp:   LD      A, $55          ; empty slot: yellow
.val:   LD      B, 6
.pr:    LD      (HL), A
        PUSH    DE
        LD      DE, 32
        ADD     HL, DE
        POP     DE
        DJNZ    .pr
        LD      A, (SCC)
        INC     A
        LD      (SCC), A
        CP      5
        JR      NZ, .pl

        ; kill tally: icons at byte cols 20,22,24, rows 55-60
        XOR     A
        LD      (SCC), A
.tl:    LD      A, (SCC)
        LD      E, A
        LD      A, (KILLS)
        CP      E
        JR      Z, .tal         ; icon >= kills -> alive icon
        JR      C, .tal
        LD      HL, TLYD        ; icon < kills -> dead ghost
        JR      .tgo
.tal:   LD      HL, TLYA
.tgo:   LD      (GPTR), HL
        LD      A, (SCC)
        ADD     A, A
        ADD     A, 20
        LD      L, A
        LD      H, 0
        LD      DE, VRAM + 55*32
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, 6
        LD      (GROW), A
.tr:    LD      HL, (GPTR)
        LD      A, (HL)
        INC     HL
        LD      (GPTR), HL
        LD      HL, (VPTR)
        LD      (HL), A
        LD      DE, 32
        ADD     HL, DE
        LD      (VPTR), HL
        LD      A, (GROW)
        DEC     A
        LD      (GROW), A
        JR      NZ, .tr
        LD      A, (SCC)
        INC     A
        LD      (SCC), A
        CP      3
        JR      NZ, .tl
        RET

; ---- copy enemy EIDX to/from work vars --------------------------------------
ELOAD:  LD      A, (EIDX)
        LD      E, A
        LD      D, 0
        LD      HL, ENALIV
        ADD     HL, DE
        LD      A, (HL)
        PUSH    AF
        LD      A, (EIDX)
        ADD     A, A
        LD      E, A
        LD      HL, ENEMX
        ADD     HL, DE
        LD      A, (HL)
        LD      (WEX), A
        INC     HL
        LD      A, (HL)
        LD      (WEX+1), A
        LD      HL, ENEMY
        ADD     HL, DE
        LD      A, (HL)
        LD      (WEY), A
        INC     HL
        LD      A, (HL)
        LD      (WEY+1), A
        POP     AF
        RET

ESTORE: LD      A, (EIDX)
        ADD     A, A
        LD      E, A
        LD      D, 0
        LD      HL, ENEMX
        ADD     HL, DE
        LD      A, (WEX)
        LD      (HL), A
        INC     HL
        LD      A, (WEX+1)
        LD      (HL), A
        LD      HL, ENEMY
        ADD     HL, DE
        LD      A, (WEY)
        LD      (HL), A
        INC     HL
        LD      A, (WEY+1)
        LD      (HL), A
        RET

; ---- hitscan: kill the nearest alive enemy in the gun columns (14-17) -------
; uses last frame's projections + depth buffer. First match wins ties.
FIREHIT:
        LD      A, 255
        LD      (BESTI), A
        LD      (BESTC), A

        LD      A, (ENALIV+0)
        OR      A
        JR      Z, .n0
        LD      A, (ECOLA+0)
        SUB     14
        CP      4
        JR      NC, .n0
        LD      A, (ECOLA+0)
        LD      L, A
        LD      H, HIGH DBUF
        LD      E, (HL)
        LD      A, (ECORRA+0)
        LD      C, A
        SRL     A
        SRL     A
        SRL     A
        LD      B, A
        LD      A, C
        SUB     B               ; deflated corr vs wall (matches DRAWDEMON)
        CP      E
        JR      NC, .n0
        LD      E, C            ; rank nearest by RAW corr
        LD      A, (BESTC)
        CP      E
        JR      C, .n0
        JR      Z, .n0
        LD      A, E
        LD      (BESTC), A
        XOR     A
        LD      (BESTI), A
.n0:
        LD      A, (ENALIV+1)
        OR      A
        JR      Z, .n1
        LD      A, (ECOLA+1)
        SUB     14
        CP      4
        JR      NC, .n1
        LD      A, (ECOLA+1)
        LD      L, A
        LD      H, HIGH DBUF
        LD      E, (HL)
        LD      A, (ECORRA+1)
        LD      C, A
        SRL     A
        SRL     A
        SRL     A
        LD      B, A
        LD      A, C
        SUB     B
        CP      E
        JR      NC, .n1
        LD      E, C
        LD      A, (BESTC)
        CP      E
        JR      C, .n1
        JR      Z, .n1
        LD      A, E
        LD      (BESTC), A
        LD      A, 1
        LD      (BESTI), A
.n1:
        LD      A, (ENALIV+2)
        OR      A
        JR      Z, .n2
        LD      A, (ECOLA+2)
        SUB     14
        CP      4
        JR      NC, .n2
        LD      A, (ECOLA+2)
        LD      L, A
        LD      H, HIGH DBUF
        LD      E, (HL)
        LD      A, (ECORRA+2)
        LD      C, A
        SRL     A
        SRL     A
        SRL     A
        LD      B, A
        LD      A, C
        SUB     B
        CP      E
        JR      NC, .n2
        LD      E, C
        LD      A, (BESTC)
        CP      E
        JR      C, .n2
        JR      Z, .n2
        LD      A, E
        LD      (BESTC), A
        LD      A, 2
        LD      (BESTI), A
.n2:
        LD      A, (BESTI)
        CP      255
        RET     Z               ; missed
        LD      E, A
        LD      D, 0
        LD      HL, ENALIV
        ADD     HL, DE
        LD      (HL), 0         ; demon down
        LD      D, 20           ; long death wail
        LD      E, 240
        LD      C, 2
        JP      SWEEP

; ----------------------------------------------------------------------------
PANGV:  DB      0
COLV:   DB      0
CEILN:  DB      0
WALLN:  DB      0
WALLB:  DB      0
PXV:    DW      0
PYV:    DW      0
MOVED:  DB      0
STEPC:  DB      0
FLASH:  DB      0
FIRECD: DB      0
DOORC:  DB      0
DOORT:  DB      0
GPTR:   DW      0
VPTR:   DW      0
GCOL:   DB      0
GROW:   DB      0

; ---- enemy state -------------------------------------------------------------
FCNT:   DB      0               ; frame counter (AI cadence)
EIDX:   DB      0               ; current enemy index
ENEMX:  DW      $0480, $0A80, $0780     ; spawns: (4.5,12.5) (10.5,12.5) (7.5,13.5)
ENEMY:  DW      $0C80, $0C80, $0D80     ; — in the rooms behind the doors
ENALIV: DB      1, 1, 1
ECOLA:  DB      255, 255, 255   ; last projected screen column (255 = offscreen)
ECORRA: DB      255, 255, 255   ; last projected corrected distance
EDRAWN: DB      0, 0, 0

; ---- projection / draw scratch ----------------------------------------------
WEX:    DW      0
WEY:    DW      0
DXV:    DW      0
DYV:    DW      0
ADXV:   DW      0
ADYV:   DW      0
MXV:    DW      0
MNV:    DW      0
SXF:    DB      0
SYF:    DB      0
SWF:    DB      0
DIST8:  DB      0
WCOL:   DB      0
WCORR:  DB      0
WCOCC:  DB      0               ; corr - corr/8, the occlusion-test depth
SPW:    DB      0
SPH:    DB      0
STAB:   DW      0
STOPR:  DB      0
SCST:   DB      0
SCC:    DB      0
SCA:    DB      0
BESTI:  DB      0
BESTC:  DB      0
CANDC:  DB      0               ; OCCUP: candidate cell index
OJDX:   DB      0               ; OCCUP: scan index
HLTH:   DB      0               ; player health 0-100
BITET:  DB      0               ; bite cooldown frames
FACET:  DB      0               ; ouch-face frames
FSTATE: DB      0               ; current face 0-4
KILLS:  DB      0
LHLTH:  DB      0               ; last-drawn HUD state (dirty check)
LKILL:  DB      0
LFACE:  DB      0
EYET:   DB      0               ; eye animation clock
; healthy-face glance sequence: 16 phases x 8 frames, indices into FACE0-8
EYESEQ: DB      0,0,0,0,0,5,6,6,5,0,0,7,8,8,7,0

        ALIGN   256
DBUF:   DS      32              ; per-column corrected wall distance

BASEEND:
        ASSERT  BASEEND <= $8F00    ; leave the stack region clear

        ; ---- tables live in the SD loader's expansion RAM ----
        ORG     $9000
        INCLUDE "tables.inc"

; ============================================================================
; Respawn feature: on death, SPACE resets the player and scatters up to 3
; demons onto random floor cells (Q still cold-restarts as before).
; ============================================================================

; ---- shared player-state reset, used by both cold boot and RESPAWN --------
INITPLR:
        LD      A, 64
        LD      (PANGV), A
        LD      HL, $0780
        LD      (PXV), HL
        LD      HL, $0280
        LD      (PYV), HL
        XOR     A
        LD      (FLASH), A
        LD      (FIRECD), A
        LD      (DOORT), A
        LD      (STEPC), A
        LD      (FACET), A
        LD      (BITET), A
        LD      A, 100
        LD      (HLTH), A
        LD      A, 255          ; force the first HUD redraw
        LD      (LHLTH), A
        XOR     A
        LD      (WAVE), A       ; death/cold-boot resets wave count...
        LD      A, 32
        LD      (AISTEPSZ), A   ; ...and the speed ramp back to baseline
        RET

; ---- 8-bit Galois LFSR (poly $B8, period 255) — cheap frame-driven RNG ----
RNGTICK:
        LD      A, (RNGST)
        RRCA
        JR      NC, .sk
        XOR     $B8
.sk:    LD      (RNGST), A
        RET

; ---- draw a random index 0..N-1 for a zone of N cells (bounded repeated- --
; ---- subtraction; N is small so this never loops more than a few times) --
RNDIDXN:
        LD      C, A            ; C = N
.loop:  CALL    RNGTICK
        LD      A, (RNGST)
.chk:   CP      C
        JR      C, .done
        SUB     C
        JR      .chk
.done:  RET             ; A = 0..N-1, indexes a zone table

; ---- RESPAWN: reset player, scatter 3 demons across both rooms -----------
RESPAWN:
        CALL    INITPLR
        JP      SPAWNDEMONS     ; tail call: places demons, then RETs for us

; ---- WAITFS: poll (not IRQ-driven — interrupts stay masked the whole game,
; ---- DI at boot, no EI anywhere) for one full frame-sync pulse on MMIO
; ---- bit 7, so a caller can line a LATCH mode-switch + VRAM write up with
; ---- the frame boundary instead of hitting it mid-scan. Polarity-agnostic
; ---- (waits for a transition either direction, then the return one) so it
; ---- doesn't matter whether idle is high or low. Bounded to roughly a
; ---- couple of frames' worth of polling per phase at ~3MHz so a flag that
; ---- doesn't toggle the way we expect degrades to "proceed anyway" rather
; ---- than hanging the machine solid — this is the one part of this patch
; ---- I can't confirm against real hardware, so it fails safe.
WAITFS:
        LD      BC, 4000
.w1:    LD      A, (KROW0)
        AND     $80
        JR      NZ, .w2
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, .w1
        RET                     ; timed out waiting for the first edge
.w2:    LD      BC, 4000
.w2l:   LD      A, (KROW0)
        AND     $80
        JR      Z, .done
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, .w2l
.done:  RET

; ---- WAVECLR: all 3 demons down while still alive -> heal, fanfare, ramp -
; ---- up demon speed, and drop in a fresh wave -----------------------------
WAVECLR:
        LD      A, (HLTH)
        ADD     A, 20           ; HLTH max is 100, so no 8-bit overflow risk
        CP      101
        JR      C, .seth
        LD      A, 100
.seth:  LD      (HLTH), A
        LD      A, 255          ; force an immediate HUD redraw
        LD      (LHLTH), A

        ; ---- wave count + speed ramp: +8 to demon step every 2 waves, ------
        ; ---- capped so they never outrun the 1/8-cell collision grid -------
        LD      A, (WAVE)
        INC     A
        LD      (WAVE), A
        AND     1
        JR      NZ, .noramp     ; only ramp on even wave numbers
        LD      A, (AISTEPSZ)
        CP      56
        JR      NC, .noramp     ; already at the cap
        ADD     A, 8
        LD      (AISTEPSZ), A
.noramp:

        ; ---- victory jingle: three quick ascending tones --------------------
        LD      D, 160
        LD      B, 4
        CALL    BEEP
        LD      D, 120
        LD      B, 4
        CALL    BEEP
        LD      D, 80
        LD      B, 5
        CALL    BEEP

        CALL    RNGTICK         ; extra stir since this fires mid-frame
        JP      SPAWNDEMONS     ; tail call: places demons, then RETs for us


; ---- SPAWNDEMONS: one demon guaranteed in the upper room, one guaranteed --
; ---- in the lower room, third goes to a coin-flip room. Keeps the spread -
; ---- even instead of just sampling the whole floor (which favours -------
; ---- whichever room happens to have more open tiles). --------------------
NZU     EQU     103             ; floor cells in the upper room
NZL     EQU     62              ; floor cells in the lower room

SPAWNDEMONS:
        ; -- demon 0: upper room --
        LD      A, NZU
        CALL    RNDIDXN
        LD      C, A
        LD      B, HIGH ZUC
        LD      A, (BC)
        LD      (ENEMX+1), A
        LD      B, HIGH ZUR
        LD      A, (BC)
        LD      (ENEMY+1), A
        LD      A, $80
        LD      (ENEMX+0), A
        LD      (ENEMY+0), A
        LD      A, 1
        LD      (ENALIV+0), A
        XOR     A
        LD      (EDRAWN+0), A
        LD      A, 255
        LD      (ECOLA+0), A
        LD      (ECORRA+0), A

        ; -- demon 1: lower room --
        LD      A, NZL
        CALL    RNDIDXN
        LD      C, A
        LD      B, HIGH ZLC
        LD      A, (BC)
        LD      (ENEMX+3), A
        LD      B, HIGH ZLR
        LD      A, (BC)
        LD      (ENEMY+3), A
        LD      A, $80
        LD      (ENEMX+2), A
        LD      (ENEMY+2), A
        LD      A, 1
        LD      (ENALIV+1), A
        XOR     A
        LD      (EDRAWN+1), A
        LD      A, 255
        LD      (ECOLA+1), A
        LD      (ECORRA+1), A

        ; -- demon 2: coin-flip room --
        CALL    RNGTICK
        LD      A, (RNGST)
        AND     1
        JR      Z, .d2upper
        LD      A, NZL
        CALL    RNDIDXN
        LD      C, A
        LD      B, HIGH ZLC
        LD      A, (BC)
        LD      (ENEMX+5), A
        LD      B, HIGH ZLR
        LD      A, (BC)
        LD      (ENEMY+5), A
        JR      .d2done
.d2upper:
        LD      A, NZU
        CALL    RNDIDXN
        LD      C, A
        LD      B, HIGH ZUC
        LD      A, (BC)
        LD      (ENEMX+5), A
        LD      B, HIGH ZUR
        LD      A, (BC)
        LD      (ENEMY+5), A
.d2done:
        LD      A, $80
        LD      (ENEMX+4), A
        LD      (ENEMY+4), A
        LD      A, 1
        LD      (ENALIV+2), A
        XOR     A
        LD      (EDRAWN+2), A
        LD      A, 255
        LD      (ECOLA+2), A
        LD      (ECORRA+2), A
        RET

; ---- RNG state ----
RNGST:  DB      1

; ---- wave progression: cleared-wave count, and the demon step size it -----
; ---- ramps (see AISTEP/WAVECLR). Reset to baseline in INITPLR. ------------
WAVE:      DB   0
AISTEPSZ:  DB   32

; ============================================================================
; INFOSCR: title/controls screen. Called once at boot (before the first
; INITPLR) and once on every death — no idle/timer logic, just those two
; events. Drops to VZ text mode, prints the game name and controls, blocks
; until SPACE (or Q, if EXHIBIT=0 — quits straight to the loader from here
; too), then restores hi-res and forces a full HUD repaint. Uses the same
; VRAM base and 32-byte row stride the hi-res code already uses — text mode
; is just fewer, bigger "pixels" on that same memory.
;
; CAVEAT: the string bytes below assume the standard MC6847-family text
; charset (space/digits/punctuation/uppercase sit at ASCII $20-$5F). One
; wrinkle: on this family, bit 6 of the byte toggles normal/inverse video
; for the internal glyph set, and bit 6 happens to be set for the whole
; uppercase-letter range ($41-$5A) but clear for space/digits/punctuation
; ($20-$3F) — so plain ASCII bytes render letters in inverse video while
; everything else looks normal. TXTCPY below masks that bit off (AND $3F)
; on the way into VRAM so everything comes out normal video. If the actual
; glyph *shapes* still look wrong on real hardware (not just the video
; polarity), only the IT1-IT7 bytes need remapping — nothing else here
; depends on the exact codes.
; ============================================================================
INFOSCR:
        CALL    WAITFS          ; line the mode switch up with a frame edge
        LD      A, %00000000    ; text mode, speaker off
        LD      (LATCH), A

        LD      HL, VRAM        ; blank the 16x32 text screen (512 bytes)
        LD      (HL), ' '
        LD      DE, VRAM+1
        LD      BC, 511
        LDIR

        LD      HL, IT1
        LD      DE, VRAM+2*32+13
        LD      BC, IT1E-IT1
        CALL    TXTCPY
        LD      HL, IT2
        LD      DE, VRAM+4*32+4
        LD      BC, IT2E-IT2
        CALL    TXTCPY
        LD      HL, IT3
        LD      DE, VRAM+7*32+6
        LD      BC, IT3E-IT3
        CALL    TXTCPY
        LD      HL, IT4
        LD      DE, VRAM+8*32+6
        LD      BC, IT4E-IT4
        CALL    TXTCPY
        LD      HL, IT5
        LD      DE, VRAM+9*32+6
        LD      BC, IT5E-IT5
        CALL    TXTCPY
        IF EXHIBIT=1
        LD      HL, IT6X
        LD      DE, VRAM+10*32+6
        LD      BC, IT6XE-IT6X
        CALL    TXTCPY
        ELSE
        LD      HL, IT6N
        LD      DE, VRAM+10*32+6
        LD      BC, IT6NE-IT6N
        CALL    TXTCPY
        ENDIF
        LD      HL, IT7
        LD      DE, VRAM+13*32+6
        LD      BC, IT7E-IT7
        CALL    TXTCPY

.wait:  IF EXHIBIT=0
        LD      A, (KROW0)
        AND     $10             ; Q = quit straight to the loader from here
        JR      Z, .doquit
        ENDIF
        LD      A, (KROW4)
        AND     $10             ; SPACE = go
        JR      NZ, .wait

        CALL    WAITFS          ; line this mode switch up too
        LD      A, %00001000    ; back to hi-res, speaker off
        LD      (LATCH), A
        LD      A, 255
        LD      (LHLTH), A      ; force a full HUD repaint next frame
        RET
        IF EXHIBIT=0
.doquit:
        XOR     A
        LD      (LATCH), A
        JP      0
        ENDIF

; ---- TXTCPY: copy BC bytes from (HL) to (DE), masking each byte with $3F
; ---- on the way in — see the note above INFOSCR for why (strips the
; ---- normal/inverse bit so plain ASCII text renders as normal video). ----
TXTCPY:
        LD      A, (HL)
        AND     $3F
        LD      (DE), A
        INC     HL
        INC     DE
        DEC     BC
        LD      A, B
        OR      C
        JR      NZ, TXTCPY
        RET

IT1:    DB      "VZDOOM"
IT1E:
IT2:    DB      "A DOOM CLONE FOR THE VZ"
IT2E:
IT3:    DB      "W/S MOVE  A/D TURN"
IT3E:
IT4:    DB      ",/. STRAFE   E DOOR"
IT4E:
IT5:    DB      "SPACE FIRE"
IT5E:
IT6X:   DB      "Q=QUIT (OFF IN THIS BUILD)"
IT6XE:
IT6N:   DB      "Q=QUIT TO LOADER"
IT6NE:
IT7:    DB      "PRESS ANY KEY TO PLAY"
IT7E:

; ---- Upper-room floor cells (rows 1-8, excludes player start at 2,7) -----
        ALIGN   256
ZUR:    DB      1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2
        DB      2,2,2,2,2,2,2,2,2,2,2,3,3,3,3,3
        DB      3,3,3,3,3,3,3,3,3,4,4,4,4,4,4,4
        DB      4,4,4,5,5,5,5,5,5,5,5,5,5,5,5,5
        DB      5,6,6,6,6,6,6,6,6,6,6,6,6,7,7,7
        DB      7,7,7,7,7,7,7,7,7,8,8,8,8,8,8,8
        DB      8,8,8,8,8,8,8

        ALIGN   256
ZUC:    DB      1,2,3,4,5,6,7,8,9,10,11,12,13,14,1,2
        DB      3,4,5,6,8,9,10,11,12,13,14,1,2,3,4,5
        DB      6,7,8,9,10,11,12,13,14,1,4,5,6,7,8,9
        DB      10,11,14,1,2,3,4,5,6,7,8,9,10,11,12,13
        DB      14,1,2,3,5,6,7,8,9,10,12,13,14,1,2,3
        DB      5,6,7,8,9,10,12,13,14,1,2,3,4,5,6,7
        DB      8,9,10,11,12,13,14

; ---- Lower-room floor cells (rows 10-14) ----------------------------------
        ALIGN   256
ZLR:    DB      10,10,10,10,10,10,10,10,10,10,10,10,11,11,11,11
        DB      11,11,11,11,11,11,11,11,12,12,12,12,12,12,12,12
        DB      12,12,12,12,12,12,13,13,13,13,13,13,13,13,13,13
        DB      14,14,14,14,14,14,14,14,14,14,14,14,14,14

        ALIGN   256
ZLC:    DB      1,2,3,4,5,7,8,10,11,12,13,14,1,2,3,4
        DB      5,7,8,10,11,12,13,14,1,2,3,4,5,6,7,8
        DB      9,10,11,12,13,14,1,2,3,4,7,8,11,12,13,14
        DB      1,2,3,4,5,6,7,8,9,10,11,12,13,14

BANKEND:
        ASSERT  BANKEND <= $C000       ; must stay inside fixed RAM, clear of the bank window

        SAVEBIN "build/vzdoom_kiosk.bin", START, BANKEND - START
