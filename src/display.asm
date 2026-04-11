; ============================================================================
; display.asm — CGA Display Refresh
; ============================================================================
;
; CGA text mode: 80×25, character + attribute pairs.
; CGA buffer at 8086 address $B8000 → bank 1 at $18000
; We periodically refresh the MEGA65 screen from the CGA buffer.
;
; The MEGA65 screen at $0800 (40-col) or $C000 (80-col) is updated
; from the CGA buffer. For now we use CHROUT for simplicity.

; ============================================================================
; init_display — Set up display mode
; ============================================================================
init_display:
        ; Clear screen
        lda #$93                ; PETSCII clear screen
        jsr CHROUT
        rts

; ============================================================================
; refresh_cga — Copy CGA text buffer to MEGA65 screen RAM
; ============================================================================
; Reads 80×25 characters from CGA buffer at bank 1 $18000.
; CGA format: char, attr, char, attr, ... (4000 bytes for 80×25)
; MEGA65 screen at $0800: screen codes only (no attribute byte)
;
; Converts ASCII→screen codes inline. Runs with IRQs off (no CHROUT).
;
refresh_cga:
        ; Source: CGA/MDA buffer at bank 1, $18000
        lda #$00
        sta temp_ptr
        lda #$80
        sta temp_ptr+1
        lda #$01
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ; Dest: screen RAM at $0800
        lda #$00
        sta temp_ptr2
        lda #$08
        sta temp_ptr2+1
        lda #$00
        sta temp_ptr2+2
        sta temp_ptr2+3

        ; 80×25 = 2000 characters
        lda #<2000
        sta $8FD4               ; Counter low
        lda #>2000
        sta $8FD5               ; Counter high

_rc_loop:
        ; Read ASCII char from CGA buffer (skip attribute at +1)
        ldz #0
        lda [temp_ptr],z
        ; Skip control characters (< $20)
        cmp #$20
        bcc _rc_skip
        ; Write to MEGA65 screen RAM
        sta [temp_ptr2],z
_rc_skip:

        ; Advance CGA pointer by 2 (char + attr pair)
        clc
        lda temp_ptr
        adc #2
        sta temp_ptr
        bcc +
        inc temp_ptr+1
+
        ; Advance screen pointer by 1
        inc temp_ptr2
        bne +
        inc temp_ptr2+1
+
        ; Decrement counter
        lda $8FD4
        bne +
        dec $8FD5
+       dec $8FD4
        lda $8FD4
        ora $8FD5
        bne _rc_loop
        rts

; (ascii_to_screen removed — CP437 font makes ASCII = screen code)

; ============================================================================
; ascii_to_pet — Convert ASCII character to PETSCII
; ============================================================================
; Input: A = ASCII character
; Output: A = PETSCII character
;
ascii_to_pet:
        cmp #$20
        bcc _atp_ctrl
        cmp #$60
        bcc _atp_upper
        cmp #$7B
        bcc _atp_lower
        ; >= $7B: return as-is
        rts
_atp_ctrl:
        ; Control chars: replace with space
        lda #$20
        rts
_atp_upper:
        ; $20-$5F: mostly the same in PETSCII
        cmp #$5C
        bne +
        lda #$2F                ; Backslash -> forward slash (no \ in C64 charset)
+       rts
_atp_lower:
        ; $61–$7A: lowercase a–z → PETSCII $C1–$DA
        clc
        adc #$60                ; $61+$60=$C1, $7A+$60=$DA
        rts