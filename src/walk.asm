; ============================================================================
; walk.asm — VZ-DOOM Milestone 3: walk the maze
; ============================================================================
; The M2 raycaster (verified byte-exact) plus keyboard movement:
;
;   W . . . forward          S . . . backward
;   A . . . turn left        D . . . turn right
;   , . . . strafe left      . . . . strafe right
;
; Movement: 1/8 cell per frame (the ray-march step tables double as the
; movement vectors). Turn: 2 angle units per frame (256/rev). Collision:
; X and Y are tested and committed independently against the map, which
; gives Wolf3D-style wall sliding for free.
;
; Keyboard: memory-mapped READS at $68xx — row selected by low address bits
; (active low), key state on D0-D5 (0 = pressed). Reads are invisible to
; the Pico bus capture, so polling costs the HDMI path nothing.
; Bit order verified on real hardware (docs list it reversed!):
;   $68FE row A0: D0=T D1=W D3=E D4=Q D5=R
;   $68FD row A1: D0=G D1=S D3=D D4=A D5=F
;   $68EF row A4: D0=N D1=. D3=, D4=SPACE D5=M
;
; Build:  ..\build.ps1 src\walk.asm WALK
; Exit:   RESET button
; ============================================================================

        DEVICE  NOSLOT64K

VRAM    EQU     $7000
LATCH   EQU     $6800

KROW0   EQU     $68FE           ; keyboard row A0 (W)
KROW1   EQU     $68FD           ; keyboard row A1 (A/D/S)
KROW4   EQU     $68EF           ; keyboard row A4 (, .)

TURNSPD EQU     2               ; angle units per frame

        ORG     $7AE9

START:
        DI
        LD      SP, $8FFE

        LD      A, %00001000    ; Mode 1, CSS=0
        LD      (LATCH), A

        LD      A, 64           ; facing +Y
        LD      (PANGV), A
        LD      HL, $0780       ; player (7.5, 2.5)
        LD      (PXV), HL
        LD      HL, $0280
        LD      (PYV), HL

; ----------------------------------------------------------------------------
MAIN:
        ; ---- input: 0 bit = key pressed ----
        LD      A, (KROW0)
        AND     $02             ; W (row0 bit1)
        CALL    Z, MOVEF
        LD      A, (KROW1)
        AND     $02             ; S (row1 bit1)
        CALL    Z, MOVEB
        LD      A, (KROW1)
        AND     $10             ; A (row1 bit4)
        CALL    Z, TURNL
        LD      A, (KROW1)
        AND     $08             ; D (row1 bit3)
        CALL    Z, TURNR
        LD      A, (KROW4)
        AND     $08             ; , (row4 bit3)
        CALL    Z, STRAFL
        LD      A, (KROW4)
        AND     $02             ; . (row4 bit1)
        CALL    Z, STRAFR

        ; ---- render frame (M2 raycaster, unchanged) ----
        XOR     A
        LD      (COLV), A

COL:
        LD      A, (COLV)
        ADD     A, A
        LD      E, A
        LD      A, (PANGV)
        ADD     A, 31
        SUB     E               ; A = ray angle

        LD      L, A
        LD      H, HIGH STEPXL
        LD      E, (HL)
        INC     H
        LD      D, (HL)         ; DE = stepX
        INC     H
        LD      A, (HL)
        INC     H
        LD      H, (HL)
        LD      L, A            ; HL = stepY
        PUSH    HL
        EXX
        POP     DE              ; DE' = stepY
        LD      HL, (PYV)       ; HL' = posY
        LD      B, 0            ; B'  = distance
        EXX
        LD      HL, (PXV)       ; HL  = posX
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

        LD      A, H
        AND     $0F
        LD      C, A
        OR      A
        SBC     HL, DE
        LD      A, H
        AND     $0F
        CP      C
        LD      A, $FF          ; front face: red
        JR      Z, .face
        LD      A, $AA          ; side face: blue
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

        LD      L, H
        LD      H, HIGH HLUT
        LD      A, (HL)
        LD      (WALLN), A
        LD      B, A
        LD      A, 64
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

        JP      MAIN

; ----------------------------------------------------------------------------
; Movement — all paths end in TRYX/TRYY, which test the destination cell on
; each axis independently and only commit the axes that stay in open space.
; ----------------------------------------------------------------------------

; A = movement angle -> DE = deltaX, HL = deltaY (1/8 cell, from step tables)
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

NEGDE:  XOR     A               ; DE = -DE
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

; DE = deltaX: commit PXV += DE unless cell(newX, curY) is a wall
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
        RET

; DE = deltaY: commit PYV += DE unless cell(curX, newY) is a wall
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
        RET

; ----------------------------------------------------------------------------
PANGV:  DB      0
COLV:   DB      0
CEILN:  DB      0
WALLN:  DB      0
WALLB:  DB      0
PXV:    DW      0
PYV:    DW      0

        INCLUDE "tables.inc"

CODEEND:

        SAVEBIN "build/walk.bin", START, CODEEND - START
