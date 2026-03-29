; ============================================================================
; io.asm — I/O Port Handlers
; ============================================================================
;
; 8086 IN/OUT instructions access I/O ports 0–65535.
; We emulate a subset needed for BIOS and DOS:
;   $20–$21: PIC (Programmable Interrupt Controller)
;   $40–$43: PIT (Programmable Interval Timer)
;   $60–$64: Keyboard controller
;   $3D4–$3D5: CGA CRTC registers
;   $3D8–$3D9: CGA mode/color registers
;   $3DA: CGA status register
;
; Port space is mirrored at IO_PORT_BASE in bank 1 for simple
; read/write tracking. Special ports have custom handlers.

; ============================================================================
; io_read_port — Read from I/O port
; ============================================================================
; Input:  temp32+0/+1 = 16-bit port number
; Output: A = byte read
;
io_read_port:
        lda temp32+1
        bne _irp_high

        ; Low port range (0–255) — check highest first
        lda temp32
        cmp #$60
        bcs _irp_kbd            ; $60+ → keyboard
        cmp #$40
        bcs _irp_pit            ; $40-$5F → PIT
        cmp #$3D
        bcs _irp_cga_range      ; $3D-$3F → CGA (but high byte check needed)
        cmp #$20
        bcs _irp_pic            ; $20-$3C → PIC

        ; Unhandled low port: return $FF
        lda #$FF
        rts

_irp_pic:
        ; PIC: return $00 (no pending interrupts)
        lda #$00
        rts

_irp_pit:
        ; PIT: return counter value (simplified)
        ; Port $40 = counter 0 read
        lda inst_counter        ; Use instruction counter as fake timer
        rts

_irp_kbd:
        ; Keyboard controller
        lda temp32
        cmp #$60
        beq _irp_kbd_data
        cmp #$64
        beq _irp_kbd_status
        lda #$FF
        rts
_irp_kbd_data:
        ; Return last keypress scancode
        ; TODO: implement keyboard buffer
        lda #$00
        rts
_irp_kbd_status:
        ; Keyboard status: bit 0 = data available
        lda #$00                ; No key available for now
        rts

_irp_high:
_irp_cga_range:
        ; Port $3DA: CGA status register
        lda temp32
        cmp #$DA
        bne _irp_cga_other
        lda temp32+1
        cmp #$03
        bne _irp_cga_other
        ; Toggle bit 0 (hsync) and bit 3 (vsync) for timing loops
        lda inst_counter
        and #$09                ; Bits 0 and 3 toggle
        rts

_irp_cga_other:
        lda #$00
        rts

; ============================================================================
; io_write_port — Write to I/O port
; ============================================================================
; Input:  temp32+0/+1 = port number
;         A = byte to write
;
io_write_port:
        ; Store to I/O port mirror (bank 1)
        ; For now: just ignore most writes
        ; TODO: handle PIC EOI, PIT setup, CGA mode changes
        rts

; ============================================================================
; INT 10h — Video Services
; ============================================================================
; (cursor position tracked by scr_row/scr_col in chrout_safe)

int10_handler:
        lda reg_ah
        cmp #$0E
        beq _i10_teletype
        cmp #$00
        beq _i10_set_mode
        cmp #$02
        beq _i10_set_cursor
        cmp #$03
        beq _i10_get_cursor
        cmp #$06
        beq _i10_scroll_up
        cmp #$09
        beq _i10_write_char_attr
        cmp #$0F
        beq _i10_get_mode
        ; Unsupported: return silently
        rts

_i10_teletype:
        ; AH=0E: Teletype output — write character AL to screen
        ; Debug: save last 8 chars printed to $8F50-$8F57
        lda $8F58               ; ring index
        and #$07
        tax
        lda reg_al
        sta $8F50,x
        inx
        stx $8F58
        lda reg_al
        cmp #$0A
        beq _i10t_done          ; Ignore LF — CR already does newline on MEGA65
        cmp #$0D
        beq _i10t_cr
        cmp #$08
        beq _i10t_bs            ; Backspace
        cmp #$07
        beq _i10t_done          ; Bell — ignore
        cmp #$20
        bcc _i10t_done          ; Control chars < $20 — ignore
        ; Regular character: always write and advance
        jsr ascii_to_pet
        jsr chrout_safe
_i10t_done:
        rts
_i10t_cr:
        lda #$0D
        jsr chrout_safe
        rts
_i10t_bs:
        lda #$9D                ; PETSCII cursor left
        jsr chrout_safe
        rts

_i10_set_mode:
        ; AH=00: Set video mode (AL=mode)
        ; Clear screen and home cursor
        lda #$93                ; PETSCII clear screen
        jsr chrout_safe         ; chrout_safe handles scr_row/scr_col reset
        rts

_i10_set_cursor:
        ; AH=02: Set cursor position — DH=row, DL=col, BH=page
        lda reg_dh
        sta scr_row
        lda reg_dl
        sta scr_col
        rts

_i10_get_cursor:
        ; AH=03: Get cursor position
        ; Return DH=row, DL=col, CH=cursor start, CL=cursor end
        lda scr_col
        sta reg_dx              ; DL=col
        lda scr_row
        sta reg_dx+1            ; DH=row
        lda #6
        sta reg_cx              ; CL=cursor end
        lda #7
        sta reg_cx+1            ; CH=cursor start... wait, CH is high byte
        ; Actually CX: CH=start=6, CL=end=7
        lda #$06
        sta reg_ch
        lda #$07
        sta reg_cl
        rts

_i10_scroll_up:
        ; AH=06: Scroll up — AL=lines (0=clear)
        lda reg_al
        bne _i10su_scroll
        ; AL=0: clear window — just clear screen
        lda #$93
        jsr chrout_safe
        rts
_i10su_scroll:
        ; AL>0: scroll up — adjust row tracking
        sec
        lda scr_row
        sbc reg_al
        bcs +
        lda #0
+       sta scr_row
        rts

_i10_write_char_attr:
        ; AH=09: Write character + attribute at cursor position
        ; On real PC this writes to CGA buffer WITHOUT advancing cursor.
        ; We can't do in-place writes via CHROUT, so just NOP.
        ; Real text output uses AH=0E (teletype) which we handle.
        rts

_i10_get_mode:
        ; AH=0F: Get current video mode
        ; AL=mode, AH=columns(80), BH=page(0)
        lda #VIDEO_MODE
        sta reg_al
        lda #80
        sta reg_ah
        lda #0
        sta reg_bh
        rts

; ============================================================================
; int16_handler — Keyboard Services (INT 16h)
; ============================================================================
; AH=00: Wait for keypress → AL=ASCII, AH=scancode
; AH=01: Check key available → ZF=0 if key ready (AL=ASCII, AH=scan)
;                               ZF=1 if no key
;

int16_handler:
        lda reg_ah
        cmp #$00
        beq _i16_wait_key
        cmp #$01
        beq _i16_check_key
        rts                     ; Unknown function, ignore

_i16_wait_key:
        ; AH=00: Wait for key.
        ; Use MEGA65 hardware typing queue at $D610 (ASCII direct!)
        ; No KERNAL needed — no IRQs, no ZP save/restore!
-       lda $D610               ; Read ASCII key from hardware queue
        beq -                   ; $00 = queue empty, keep polling
        sta $D610               ; Dequeue the event (write any value)
        ; Map MEGA65 key codes to IBM PC codes
        cmp #$14                ; MEGA65 DELETE/backspace (PETSCII DEL)
        beq _i16_bs
        cmp #$7F                ; ASCII DEL
        beq _i16_bs
        ; A = ASCII key code
        sta reg_al
        lda #$00
        sta reg_ah              ; Fake scancode
        rts
_i16_bs:
        lda #$08                ; IBM PC backspace
        sta reg_al
        lda #$0E                ; Scancode for backspace
        sta reg_ah
        rts

_i16_check_key:
        ; AH=01: Non-blocking check.
        ; Peek at hardware typing queue — don't dequeue
        lda $D610               ; Read ASCII key from hardware queue
        beq _i16_no_key         ; $00 = no key
        ; Map MEGA65 key codes
        cmp #$14                ; MEGA65 DELETE/backspace
        bne +
        lda #$08
+       cmp #$7F                ; ASCII DEL
        bne +
        lda #$08
+       ; Key available (don't dequeue — AH=00 will do that)
        sta reg_al
        lda #$00
        sta reg_ah
        lda #0
        sta flag_zf             ; ZF=0 → key available
        rts
_i16_no_key:
        lda #1
        sta flag_zf             ; ZF=1 → no key
        rts

; ============================================================================
; pet_to_ascii — Convert PETSCII to ASCII
; ============================================================================
; Input: A = PETSCII code
; Output: A = ASCII code
;
pet_to_ascii:
        ; CR → CR
        cmp #$0D
        beq _pta_done
        ; Uppercase A-Z: PETSCII $41-$5A → ASCII $41-$5A (same)
        cmp #$41
        bcc _pta_check_lower
        cmp #$5B
        bcc _pta_done           ; Already correct
_pta_check_lower:
        ; Lowercase a-z: PETSCII $C1-$DA → ASCII $61-$7A
        cmp #$C1
        bcc _pta_other
        cmp #$DB
        bcs _pta_other
        sec
        sbc #$60                ; $C1-$60 = $61 = 'a'
        rts
_pta_other:
        ; Numbers and common symbols are same in PETSCII and ASCII
        ; for the $20-$3F range
_pta_done:
        rts

; ============================================================================
; chrout_safe — Output character without trashing ZP
; ============================================================================
; Input: A = PETSCII character to output
; Writes directly to MEGA65 screen RAM — no KERNAL, no IRQs.
;
SCREEN_BASE     = $0800         ; MEGA65 default 80-col screen RAM
SCR_COLS        = 80
SCR_ROWS        = 25

chrout_safe:
        cmp #$0D
        beq _cs_cr
        cmp #$93
        beq _cs_cls
        cmp #$11
        beq _cs_down
        cmp #$1D
        beq _cs_right
        cmp #$9D
        beq _cs_left
        cmp #$13
        beq _cs_home
        ; Regular character: write to screen RAM at scr_row * 80 + scr_col
        pha
        jsr calc_scr_ptr        ; temp_ptr = screen address
        pla
        jsr pet_to_screen       ; Convert PETSCII to screen code
        ldz #0
        sta [temp_ptr],z
        ; Advance column
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc _cs_done
        ; Wrap to next line
        lda #0
        sta scr_col
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc _cs_done
        jsr do_scr_scroll
_cs_done:
        rts

_cs_cr:
        lda #0
        sta scr_col
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       rts

_cs_cls:
        ; Clear screen via DMA fill
        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81, $00          ; Dest MB = 0
        .byte $00               ; End options
        .byte $03               ; Command = FILL
        .word 2000              ; Count = 80*25
        .word $0020             ; Fill value = $20 (space screen code) in low byte
        .byte $00               ; Source bank (unused for fill, but value used as fill)
        .word SCREEN_BASE       ; Dest address
        .byte $00               ; Dest bank
        .byte $00, $00, $00     ; Modulo
        lda #0
        sta scr_row
        sta scr_col
        rts

_cs_down:
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       rts

_cs_right:
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc +
        lda #SCR_COLS-1
        sta scr_col
+       rts

_cs_left:
        lda scr_col
        beq +
        dec scr_col
+       rts

_cs_home:
        lda #0
        sta scr_row
        sta scr_col
        rts

; --- Calculate screen pointer from scr_row/scr_col ---
; Output: temp_ptr = SCREEN_BASE + scr_row * 80 + scr_col
calc_scr_ptr:
        ; row * 80 = row * 64 + row * 16
        lda scr_row
        asl
        asl
        asl
        asl
        sta scratch_a           ; row*16 low
        lda scr_row
        lsr
        lsr
        lsr
        lsr
        sta scratch_b           ; row*16 high
        lda scr_row
        asl
        asl
        asl
        asl
        asl
        asl
        sta scratch_c           ; row*64 low
        lda scr_row
        lsr
        lsr
        sta scratch_d           ; row*64 high
        clc
        lda scratch_a
        adc scratch_c
        sta scratch_a           ; (row*80) low
        lda scratch_b
        adc scratch_d
        sta scratch_b           ; (row*80) high
        ; Add column
        clc
        lda scratch_a
        adc scr_col
        sta scratch_a
        lda scratch_b
        adc #0
        sta scratch_b
        ; Add SCREEN_BASE
        clc
        lda scratch_a
        adc #<SCREEN_BASE
        sta temp_ptr
        lda scratch_b
        adc #>SCREEN_BASE
        sta temp_ptr+1
        lda #$00
        sta temp_ptr+2
        sta temp_ptr+3
        rts

; --- Scroll screen up one line via DMA ---
do_scr_scroll:
        lda scr_row
        cmp #SCR_ROWS
        bcc do_scr_scroll_done     ; Not past bottom, no scroll needed
        ; DMA copy: row 1-24 → row 0-23 (1920 bytes = 24*80)
        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81, $00          ; Dest MB = 0
        .byte $00               ; End options
        .byte $00               ; Command = COPY
        .word 1920              ; Count = 24 * 80
        .word SCREEN_BASE+SCR_COLS ; Source = row 1
        .byte $00               ; Source bank
        .word SCREEN_BASE       ; Dest = row 0
        .byte $00               ; Dest bank
        .byte $00, $00, $00     ; Modulo
        ; Clear last row (fill with spaces)
        lda #$00
        sta $D707
        .byte $80, $00
        .byte $81, $00
        .byte $00
        .byte $03               ; Command = FILL
        .word SCR_COLS          ; Count = 80
        .word $0020             ; Fill value = space
        .byte $00
        .word SCREEN_BASE+1920  ; Dest = row 24
        .byte $00
        .byte $00, $00, $00
        lda #SCR_ROWS-1
        sta scr_row             ; Cursor on last row
do_scr_scroll_done:
        rts

; Screen position tracking
scr_row         .byte 0
scr_col         .byte 0

; Convert PETSCII to screen code (lowercase charset mode)
; Lowercase charset: screen $01-$1A = lowercase a-z
;                    screen $41-$5A = uppercase A-Z
;                    screen $00 = @
pet_to_screen:
        ; $20-$3F → $20-$3F (space, digits, punctuation)
        cmp #$40
        bcc _pts_done
        beq _pts_at             ; $40 (@) → $00
        ; $41-$5A (PETSCII uppercase A-Z) → screen $41-$5A (uppercase)
        cmp #$5B
        bcc _pts_done           ; Stay as-is
        ; $5B-$5F ([\]^_) → screen $1B-$1F
        cmp #$60
        bcc _pts_bracket
        ; $60-$7F → use as-is
        cmp #$80
        bcc _pts_done
        ; $80-$BF → mask off bit 7 (reverse/alternate)
        cmp #$C0
        bcc _pts_mask
        ; $C1-$DA (PETSCII lowercase a-z) → screen $01-$1A
        cmp #$DB
        bcc _pts_lower
        ; $DB+ → mask
_pts_mask:
        and #$7F
        rts
_pts_at:
        lda #$00
        rts
_pts_bracket:
        sec
        sbc #$40                ; $5B→$1B, $5F→$1F
        rts
_pts_lower:
        sec
        sbc #$C0                ; $C1→$01, $DA→$1A
_pts_done:
        rts

