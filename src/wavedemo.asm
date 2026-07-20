; ============================================================================
; wavedemo.asm — VZ-DOOM Milestone 1: column renderer proof
; ============================================================================
; Renders 32 vertical "wall slice" columns in Mode 1 (128x64, 2bpp) with
; heights from a scrolling wave table. This is the raycaster's column
; renderer running against fake ray results — proves the rendering pipeline
; and measures real frame rate before the DDA goes in.
;
; What you should see on the VZ (and the HDMI shadow): a red "wall" whose
; height undulates and scrolls horizontally, green ceiling above, yellow
; floor below. Full screen redraw every frame, free-running.
;
; Frame rate estimate: ~68K T-states/frame -> ~50 fps.
; Pico telemetry check: vram/s ~= 2048 x fps (expect ~100K writes/s).
;
; Build:  ..\tools\sjasmplus.exe wavedemo.asm  (or use ..\build.ps1)
; Load:   copy WAVEDEMO.VZ to SD, LOAD "WAVEDEMO" — autostarts (type F1)
; Exit:   RESET button (we run with DI, forever)
; ============================================================================

        DEVICE  NOSLOT64K

VRAM    EQU     $7000           ; Mode 1 framebuffer, 32 bytes/row, 64 rows
LATCH   EQU     $6800           ; VDC output latch: b3=mode(1=gfx), b4=CSS

; Column byte values: 4 pixels of 2 bits each
CEIL_BYTE  EQU  $00             ; 4x colour 0 (green)
WALL_BYTE  EQU  $FF             ; 4x colour 3 (red)
FLOOR_BYTE EQU  $55             ; 4x colour 1 (yellow)

        ORG     $7AE9

START:
        DI                      ; ROM VBlank IRQ rewrites the latch — keep off
        LD      SP, $8FFE       ; own stack, top of base RAM

        LD      A, %00001000    ; graphics mode, CSS=0, speaker bits 0
        LD      (LATCH), A

        XOR     A
        LD      (PHASE), A

; ----------------------------------------------------------------------------
; Main loop: draw 32 columns, advance wave phase, repeat
; ----------------------------------------------------------------------------
MAIN:
        LD      C, 0            ; C = column 0..31

COLLOOP:
        ; wall height = HTAB[(column + phase) & 31]   (even values 2..62)
        LD      A, (PHASE)
        ADD     A, C
        AND     31
        LD      L, A
        LD      H, HIGH HTAB    ; HTAB is 256-aligned
        LD      A, (HL)
        LD      (WALLN), A

        ; ceiling rows = floor rows = (64 - height) / 2
        LD      B, A
        LD      A, 64
        SUB     B
        SRL     A
        LD      (CEILN), A

        ; HL = VRAM + column  (VRAM is 256-aligned, column < 32)
        LD      H, HIGH VRAM
        LD      L, C
        LD      DE, 32          ; stride: next row, same column

        ; --- ceiling segment ---
        LD      A, (CEILN)
        OR      A
        JR      Z, .wall        ; height 62 max -> min 1 row, but be safe
        LD      B, A
        LD      A, CEIL_BYTE
.cl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .cl

        ; --- wall segment ---
.wall:  LD      A, (WALLN)
        LD      B, A
        LD      A, WALL_BYTE
.wl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .wl

        ; --- floor segment ---
        LD      A, (CEILN)
        OR      A
        JR      Z, .next
        LD      B, A
        LD      A, FLOOR_BYTE
.fl:    LD      (HL), A
        ADD     HL, DE
        DJNZ    .fl

.next:  INC     C
        LD      A, C
        CP      32
        JR      NZ, COLLOOP

        ; advance wave phase (scrolls the wall)
        LD      A, (PHASE)
        INC     A
        AND     31
        LD      (PHASE), A

        JP      MAIN

; ----------------------------------------------------------------------------
; Variables
; ----------------------------------------------------------------------------
PHASE:  DB      0
CEILN:  DB      0
WALLN:  DB      0

; ----------------------------------------------------------------------------
; Wave table: 32 wall heights, all even, 2..62 (aligned so index -> L only)
; ----------------------------------------------------------------------------
        ALIGN   256
HTAB:
        DB      32,38,44,50,54,58,60,62
        DB      62,62,60,58,54,50,44,38
        DB      32,26,20,14,10, 6, 4, 2
        DB       2, 2, 4, 6,10,14,20,26

CODEEND:

        SAVEBIN "build/wavedemo.bin", START, CODEEND - START
