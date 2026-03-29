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
; refresh_cga — Copy CGA text buffer to screen
; ============================================================================
; Reads 80×25 characters from CGA buffer at $02A000.
; Writes to screen using CHROUT (slow but reliable for testing).
;
; CGA format: char, attr, char, attr, ... (4000 bytes for 80×25)
;
refresh_cga:
        ; Home cursor
        lda #$13                ; PETSCII home
        jsr CHROUT

        ; Set up pointer to CGA buffer (bank 2 at $2A000)
        lda #$00
        sta temp_ptr
        lda #$A0
        sta temp_ptr+1
        lda #$02                ; Bank 2
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldy #0                  ; Row counter
_rc_row:
        ldx #0                  ; Column counter
_rc_col:
        ; Read character (skip attribute)
        ldz #0
        lda [temp_ptr],z
        ; Convert ASCII to PETSCII (simplified)
        jsr ascii_to_pet
        jsr CHROUT

        ; Advance pointer by 2 (char + attr)
        clc
        lda temp_ptr
        adc #2
        sta temp_ptr
        bcc +
        inc temp_ptr+1
+
        inx
        cpx #CGA_COLS
        bne _rc_col

        ; Newline
        lda #13
        jsr CHROUT

        iny
        cpy #CGA_ROWS
        bne _rc_row
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
        ; $60–$7A: lowercase a–z → PETSCII lowercase
        ; PETSCII lowercase is $41–$5A in lowercase mode
        ; or just return as-is and rely on screen mode
        sec
        sbc #$20                ; Convert to uppercase range
        rts