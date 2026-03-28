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

        ; Low port range (0–255)
        lda temp32
        cmp #$3D
        bcs _irp_cga_range
        cmp #$60
        bcs _irp_kbd
        cmp #$40
        bcs _irp_pit
        cmp #$20
        bcs _irp_pic

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
        ; Count 'F' prints at $8FE0 (tracks how many times "FreeDOS" is printed)
        lda reg_al
        cmp #$46                ; 'F'
        bne +
        inc $8FE0
+
        lda reg_al
        cmp #$0A
        beq _i10t_done          ; Ignore LF — CR already does newline on MEGA65
        cmp #$0D
        beq _i10t_cr
        ; Regular character: write to CGA buffer
        ; TODO: track cursor position in BDA and write to CGA
        ; For now: just CHROUT
        jsr ascii_to_pet
        jsr chrout_safe
_i10t_done:
        rts
_i10t_cr:
        lda #$0D
        jsr chrout_safe
        rts

_i10_set_mode:
        ; AH=00: Set video mode (AL=mode)
        ; Just acknowledge — we always run mode 3 (80x25 text)
        rts

_i10_set_cursor:
        ; AH=02: Set cursor position — DH=row, DL=col, BH=page
        ; TODO: update BDA cursor position
        rts

_i10_get_cursor:
        ; AH=03: Get cursor position
        ; Return DH=row, DL=col, CH=cursor start, CL=cursor end
        lda #0
        sta reg_dx              ; DL=col=0
        sta reg_dx+1            ; DH=row=0
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
        ; TODO: implement CGA buffer scrolling
        rts

_i10_write_char_attr:
        ; AH=09: Write character + attribute at cursor
        ; AL=char, BL=attribute, CX=count
        ; Simplified: just write char via teletype
        lda reg_al
        jsr ascii_to_pet
        jsr chrout_safe
        rts

_i10_get_mode:
        ; AH=0F: Get current video mode
        ; AL=mode(3), AH=columns(80), BH=page(0)
        lda #$03
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
GETIN           = $FFE4

int16_handler:
        lda reg_ah
        cmp #$00
        beq _i16_wait_key
        cmp #$01
        beq _i16_check_key
        rts                     ; Unknown function, ignore

_i16_wait_key:
        ; AH=00: Wait for key.
        ; Save ZP once, keep IRQs on for the entire wait so KERNAL
        ; keyboard scanner has time to process keypresses.
        jsr save_zp
        cli
-       jsr GETIN
        cmp #$00
        beq -                   ; No key yet, keep polling
        sei
        jsr restore_zp
        ; A = PETSCII key code. Convert to ASCII and store.
        jsr pet_to_ascii
        sta reg_al
        ; Fake scancode in AH (just use 0 for now)
        lda #$00
        sta reg_ah
        rts

_i16_check_key:
        ; AH=01: Non-blocking check. Use GETIN once.
        jsr getin_safe
        cmp #$00
        beq _i16_no_key
        ; Key available
        jsr pet_to_ascii
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
; chrout_safe — Call CHROUT without KERNAL IRQ trashing our ZP
; ============================================================================
; Input: A = PETSCII character to output
; Saves ZP $90–$C0 before enabling IRQs, restores after.
;
chrout_safe:
        pha                     ; Save character
        jsr save_zp
        pla                     ; Recover character
        cli
        jsr CHROUT
        sei
        jsr restore_zp
        rts

; ============================================================================
; getin_safe — Call GETIN without KERNAL IRQ trashing our ZP
; ============================================================================
; Output: A = PETSCII key (0 = no key)
;
getin_safe:
        jsr save_zp
        cli
        jsr GETIN
        sei
        pha                     ; Save key
        jsr restore_zp
        pla                     ; Recover key
        rts

; --- Save/restore ZP $70–$C0 (81 bytes) to shadow buffer ---
; Covers 32-bit pointers ($70-$8F) AND cache/scratch state ($90-$C0)
; Both ranges can be trashed by KERNAL IRQ during CLI
save_zp:
        ldx #0
-       lda $70,x
        sta ZP_SHADOW,x
        inx
        cpx #$51                ; $C0 - $70 + 1 = 81 = $51
        bne -
        rts

restore_zp:
        ldx #0
-       lda ZP_SHADOW,x
        sta $70,x
        inx
        cpx #$51
        bne -
        ; Force recomputation of cached segment bases
        lda #1
        sta cs_dirty
        sta ss_dirty
        sta ds_dirty
        rts