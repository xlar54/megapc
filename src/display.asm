; ============================================================================
; display.asm — CGA Display Refresh
; ============================================================================
;
; CGA text mode: 80×25, character + attribute pairs.
; CGA buffer at 8086 address $B8000 → bank 2 at $02A000
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
; Reads 80×25 characters from CGA buffer at $02A000.
; CGA format: char, attr, char, attr, ... (4000 bytes for 80×25)
; MEGA65 screen at $0800: screen codes only (no attribute byte)
;
; Converts ASCII→screen codes inline. Runs with IRQs off (no CHROUT).
;
refresh_cga:
        ; Source: CGA buffer at bank 2, $2A000
        lda #$00
        sta temp_ptr
        lda #$A0
        sta temp_ptr+1
        lda #$02
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
        ; Convert ASCII to screen code
        jsr ascii_to_screen
        ; Write to MEGA65 screen RAM
        ldz #0
        sta [temp_ptr2],z

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

; ============================================================================
; ascii_to_screen — Convert ASCII to MEGA65 screen code
; ============================================================================
; Input: A = ASCII character
; Output: A = screen code for MEGA65 (lowercase charset mode)
;
ascii_to_screen:
        cmp #$00
        beq _ats_space          ; NUL → space
        cmp #$20
        bcc _ats_space          ; Control chars → space
        cmp #$40
        bcc _ats_done           ; $20-$3F: same as screen code
        cmp #$60
        bcc _ats_upper          ; $40-$5F: uppercase letters
        cmp #$7B
        bcc _ats_lower          ; $60-$7A: lowercase letters
        cmp #$7F
        bcc _ats_done           ; $7B-$7E: as-is
_ats_space:
        lda #$20                ; Space
_ats_done:
        rts
_ats_upper:
        ; ASCII $40-$5F → screen codes $00-$1F (uppercase in lowercase charset)
        sec
        sbc #$40
        rts
_ats_lower:
        ; ASCII $60-$7A → screen codes $01-$1A? No.
        ; In MEGA65 lowercase charset: lowercase a-z = screen codes $01-$1A
        sec
        sbc #$60
        clc
        adc #$01
        rts

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
        ; $20–$5F: mostly the same in PETSCII
        rts
_atp_lower:
        ; $61–$7A: lowercase a–z → PETSCII $C1–$DA
        clc
        adc #$60                ; $61+$60=$C1, $7A+$60=$DA
        rts