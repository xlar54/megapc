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
        cmp #$62
        bcs _irp_kbd            ; $62+ → keyboard
        cmp #$61
        beq _irp_port61         ; $61 → speaker/PPI port B
        cmp #$60
        beq _irp_kbd_data       ; $60 → keyboard data
        cmp #$40
        bcs _irp_pit            ; $40-$5F → PIT
        cmp #$3D
        bcs _irp_cga_range      ; $3D-$3F → CGA (but high byte check needed)
        cmp #$20
        bcs _irp_pic            ; $20-$3C → PIC

        ; Unhandled low port: return $FF
        lda #$FF
        rts

_irp_port61:
        ; Port $61: return current speaker/PPI state
        lda spk_port61
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
        lda temp32+1
        cmp #$03
        bne _irp_cga_other
        lda temp32
        cmp #$DA
        beq _irp_retrace
        ; Port $3BA: MDA status register (same behavior as $3DA)
        cmp #$BA
        beq _irp_retrace
        bra _irp_cga_other

_irp_retrace:
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
        ; Input: temp32 = port number (16-bit), A = value to write
        ; Check port high byte first for fast dispatch
        lda temp32+1
        bne _iow_high_ports      ; Port >= $100
        ; Low ports ($00-$FF)
        lda temp32
        cmp #$43
        beq _iow_pit_cmd
        cmp #$42
        beq _iow_pit_data
        cmp #$61
        beq _iow_port61
        rts

_iow_high_ports:
        ; Check for CRTC index/data registers
        cmp #$03
        bne _iow_done
        lda temp32
        cmp #$D4                ; CGA CRTC index ($3D4)
        beq _iow_crtc_index
        cmp #$B4                ; MDA CRTC index ($3B4)
        beq _iow_crtc_index
        cmp #$D5                ; CGA CRTC data ($3D5)
        beq _iow_crtc_data
        cmp #$B5                ; MDA CRTC data ($3B5)
        beq _iow_crtc_data
_iow_done:
        rts

_iow_crtc_index:
        ; Save the selected CRTC register index
        lda reg_al
        sta io_crtc_reg               ; CRTC selected register
        rts

_iow_crtc_data:
        ; Write to the selected CRTC register
        lda io_crtc_reg               ; Which register?
        cmp #$0E
        beq _iow_cursor_hi
        cmp #$0F
        beq _iow_cursor_lo
        rts                     ; Ignore other CRTC registers

_iow_cursor_hi:
        ; Cursor address high byte
        lda reg_al
        sta io_save_a               ; Save cursor high byte
        rts

_iow_cursor_lo:
        ; Cursor address low byte — compute row/col and update sprite
        ; Cursor address = row * 80 + col (16-bit)
        lda reg_al
        sta io_save_b               ; Save cursor low byte
        ; Divide cursor address by 80 to get row and col
        ; address = io_save_a:io_save_b (high:low)
        ; Use repeated subtraction: row = address / 80, col = address % 80
        lda io_save_b
        sta scratch_a           ; Working low byte
        lda io_save_a
        sta scratch_b           ; Working high byte
        lda #0
        sta scratch_c           ; Row counter
_iow_div80:
        ; Subtract 80 from working value
        sec
        lda scratch_a
        sbc #80
        tax                     ; Save result low
        lda scratch_b
        sbc #0
        bcc _iow_div_done       ; Went negative — done
        sta scratch_b
        stx scratch_a
        inc scratch_c           ; Row++
        bra _iow_div80
_iow_div_done:
        ; scratch_c = row, scratch_a = col (remainder)
        lda scratch_c
        sta scr_row
        lda scratch_a
        sta scr_col
        jsr cursor_update
        rts

; ============================================================================
; PC Speaker emulation via SID chip
; ============================================================================
; PIT Timer 2 sets frequency, port $61 gates speaker on/off.
; Maps PC speaker frequency to MEGA65 SID voice 1.
;
; State variables:
; Speaker / PIT state — defined in globals.asm
; (spk_pit_lobyte, spk_pit_hibyte, spk_pit_latch, spk_port61)

_iow_pit_cmd:
        ; Port $43: PIT command register
        ; We only care about Timer 2 (bits 7:6 = 10)
        lda reg_al
        and #$C0
        cmp #$80                ; Timer 2?
        bne _iow_pit_cmd_done
        ; Reset latch to expect low byte first
        lda #0
        sta spk_pit_latch
_iow_pit_cmd_done:
        rts

_iow_pit_data:
        ; Port $42: PIT Timer 2 data
        ; Two sequential writes: low byte then high byte
        lda spk_pit_latch
        bne _iow_pit_hi
        ; Low byte
        lda reg_al
        sta spk_pit_lobyte
        lda #1
        sta spk_pit_latch       ; Next write is high byte
        rts
_iow_pit_hi:
        ; High byte — now compute SID frequency
        lda reg_al
        sta spk_pit_hibyte
        lda #0
        sta spk_pit_latch       ; Reset for next time
        ; Convert PC PIT divider to SID frequency
        ; PC freq = 1193182 / divider
        ; SID freq register = PC_freq * 65536 / 985248 (PAL)
        ; Simplified: SID = (1193182 * 65536) / (985248 * divider)
        ;           ≈ 79384678 / divider
        ; For practical purposes: SID ≈ $04BD0000 / divider
        ; But 32-bit divide is expensive. Use lookup or approximation:
        ; SID_freq ≈ 17 * (65536 / divider) = 17 * 65536 / divider
        ; Simpler: use hardware multiplier
        ; SID = $04BD * $0100 / divider (approx)
        ;
        ; Even simpler: SID_freq = $04BD0000 / divider
        ; Since divider is 16-bit, we can use: result = $04BD * (256 / divider_hi)
        ; But this loses precision for small dividers.
        ;
        ; Pragmatic approach: use the MEGA65 hardware divider if available,
        ; or just scale linearly. For now:
        ; SID_freq = $FFFF * 1193182 / (985248 * divider)
        ;          ≈ $FFFF * 1.211 / divider
        ;          ≈ $1362E / divider (for 16-bit result)
        ;
        ; Use hardware multiplier for: $04BD00 / divider
        ; $D770-$D773 = dividend, $D774-$D777 = divisor
        ; Result at $D778-$D77B
        ; Actually the MEGA65 math unit does multiply, not divide.
        ; Let's just do a simple shift approximation:
        ; If divider < 256: SID = high_table[divider]
        ; If divider >= 256: SID = $04BD00 >> (log2(divider) - 8)
        ;
        ; Simplest correct approach: repeated subtraction divide
        ; But that's slow for large dividers.
        ;
        ; FASTEST approach: approximate with bit shifts
        ; SID ≈ $04BD shifted right by the position of the highest bit in divider
        ; This gives the right order of magnitude.
        ;
        ; Actually, let's just compute it properly using 16-bit divide:
        ; We want SID = $04BD * 256 / divider = $04BD00 / divider
        ; dividend = $04BD00 (24-bit), divisor = divider (16-bit)
        ;
        ; 24÷16 divide via shift-subtract:
        lda #$00
        sta scratch_a           ; Result low
        sta scratch_b           ; Result high
        ; Dividend = $131700 (24-bit). Result shifted left 4 after divide.
        lda #$00
        sta ldiv_dividend0               ; Dividend byte 0 (low)
        lda #$17
        sta ldiv_dividend1               ; Dividend byte 1
        lda #$13
        sta ldiv_dividend2               ; Dividend byte 2 (high)
        ; Divisor in spk_pit_lobyte:spk_pit_hibyte
        ; Check for zero divisor
        lda spk_pit_lobyte
        ora spk_pit_hibyte
        beq _iow_pit_hi_done   ; Divisor zero — skip

        ; 16-bit result = 24-bit dividend / 16-bit divisor
        ; Dividend = $04BD00, Divisor = spk_pit_hibyte:spk_pit_lobyte
        ; Using shift-subtract: 16 iterations
        lda #0
        sta scratch_a           ; Remainder low
        sta scratch_b           ; Remainder high
        sta ldiv_result_lo               ; Result low (MUST init to 0)
        sta ldiv_result_hi               ; Result high
        ldx #24                 ; 24 iterations for 24-bit dividend
_iow_div_loop:
        ; Shift dividend left (MSB into remainder)
        asl ldiv_dividend0
        rol ldiv_dividend1
        rol ldiv_dividend2
        rol scratch_a
        rol scratch_b
        ; Shift result left
        asl ldiv_result_lo
        rol ldiv_result_hi
        ; Try subtract divisor from remainder
        sec
        lda scratch_a
        sbc spk_pit_lobyte
        tay                     ; Save tentative low
        lda scratch_b
        sbc spk_pit_hibyte
        bcc _iow_div_no_sub     ; Remainder < divisor, don't subtract
        ; Remainder >= divisor: commit subtraction, set result bit
        sta scratch_b
        sty scratch_a
        inc ldiv_result_lo               ; Set low bit of result
_iow_div_no_sub:
        dex
        bne _iow_div_loop
        ; Result in ldiv_result_lo:ldiv_result_hi — shift left 4 for correct SID frequency
        asl ldiv_result_lo
        rol ldiv_result_hi
        asl ldiv_result_lo
        rol ldiv_result_hi
        asl ldiv_result_lo
        rol ldiv_result_hi
        asl ldiv_result_lo
        rol ldiv_result_hi
        ; Write to SID voice 1 frequency
        lda ldiv_result_lo
        sta $D400               ; SID freq low
        lda ldiv_result_hi
        sta $D401               ; SID freq high
_iow_pit_hi_done:
        rts

_iow_port61:
        ; Port $61: speaker control
        ; Bit 0 = PIT Timer 2 gate, Bit 1 = Speaker data
        ; Both set = tone on
        lda reg_al
        sta spk_port61
        and #$03
        cmp #$03
        beq _iow_spk_on
        ; Speaker off — just clear gate bit
        lda #$40                ; Gate off, pulse waveform
        sta $D404
        rts
_iow_spk_on:
        ; Speaker on — apply frequency and gate
        lda #$0F
        sta $D418               ; Volume = 15
        lda #$08
        sta $D402               ; Pulse width low
        lda #$08
        sta $D403               ; Pulse width high
        lda #$00
        sta $D405               ; Attack=0, Decay=0
        lda #$F0
        sta $D406               ; Sustain=15, Release=0
        lda ldiv_result_lo
        sta $D400               ; Freq low
        lda ldiv_result_hi
        sta $D401               ; Freq high
        lda #$41                ; Gate ON + pulse
        sta $D404
        rts

; ============================================================================
; INT 10h — Video Services
; ============================================================================
; (cursor position tracked by scr_row/scr_col in con_write_char and chrout_safe)

int10_handler:
        lda reg_ah
        cmp #$0E
        beq _i10_teletype
        cmp #$00
        beq _i10_set_mode
        cmp #$01
        beq _i10_set_cursor_shape
        cmp #$02
        beq _i10_set_cursor
        cmp #$03
        beq _i10_get_cursor
        cmp #$06
        beq _i10_scroll_up
        cmp #$07
        beq _i10_scroll_down
        cmp #$08
        beq _i10_read_char_attr
        cmp #$09
        beq _i10_write_char_attr
        cmp #$0A
        beq _i10_write_char_only
        cmp #$0F
        beq _i10_get_mode
        cmp #$13
        beq _i10_write_string
        ; Unsupported: return silently
        rts

_i10_teletype:
        ; AH=0E: Teletype output — route through con_write_char
        lda reg_al
        jsr con_write_char
        rts

_i10_set_cursor_shape:
        ; AH=01: Set cursor shape — CH=start scan line, CL=end scan line
        ; Bit 5 of CH = cursor hidden
        ; Store in BDA at 0040:0060 (end) and 0040:0061 (start)
        lda #$60
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda reg_cl              ; End scan line
        ldz #0
        sta [temp_ptr],z
        lda reg_ch              ; Start scan line
        ldz #1
        sta [temp_ptr],z
        ; Check bit 5 of CH: cursor hidden
        lda reg_ch
        and #$20
        bne _i10_hide_cur
        ; Visible: set shape from scan line range
        lda reg_ch
        and #$1F                ; Start scan line (0-7)
        sta scratch_c           ; Save start
        lda reg_cl
        and #$1F                ; End scan line (0-7)
        sta scratch_d           ; Save end
        jsr cursor_set_shape
        jsr cursor_show
        rts
_i10_hide_cur:
        jsr cursor_hide
        rts

_i10_set_mode:
        ; AH=00: Set video mode (AL=mode)
        ; Update BDA current video mode (40:49) with requested mode
        lda reg_al
        and #$7F                ; Strip bit 7 (no-clear flag on some BIOSes)
        pha                     ; Save the mode value
        lda #$49
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        pla                     ; Recover mode value
        ldz #0
        sta [temp_ptr],z        ; Write mode to BDA 40:49
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
        jsr cursor_update
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
        ; AH=06: Scroll up — AL=lines (0=clear window)
        lda reg_al
        bne _i10su_scroll
        ; AL=0: clear window (CH,CL)-(DH,DL) — respects window boundaries
        jsr do_clear_window
        ; Also clear MEGA65 screen RAM for the same region
        jsr do_clear_window_scr
        rts
_i10su_scroll:
        ; AL>0: scroll up AL lines (preserve cursor position)
        sta io_line_count               ; Save line count (do_scr_scroll clobbers X)
        lda scr_row
        pha
        lda scr_col
        pha
_i10su_loop:
        lda #SCR_ROWS
        sta scr_row
        jsr do_scr_scroll
        dec io_line_count
        bne _i10su_loop
        pla
        sta scr_col
        pla
        sta scr_row
        rts

_i10_scroll_down:
        ; AH=07: Scroll down — AL=lines (0=clear entire window)
        lda reg_al
        bne _i10sd_scroll
        ; AL=0: clear window (CH,CL)-(DH,DL) — respects window boundaries
        jsr do_clear_window
        jsr do_clear_window_scr
        rts
_i10sd_scroll:
        ; AL>0: scroll down AL lines (preserve cursor position)
        sta io_line_count               ; Save count (do_scr_scroll_down clobbers X)
        lda scr_row
        pha
        lda scr_col
        pha
_i10sd_loop:
        jsr do_scr_scroll_down
        dec io_line_count
        bne _i10sd_loop
        pla
        sta scr_col
        pla
        sta scr_row
        rts

_i10_read_char_attr:
        ; AH=08: Read character and attribute at cursor position
        ; Read from guest video buffer at $18000 + (row*80+col)*2
        jsr cwc_calc_vidbuf
        ldz #0
        lda [temp_ptr2],z       ; Character byte
        sta reg_al
        ldz #1
        lda [temp_ptr2],z       ; Attribute byte
        sta reg_ah
        rts

_i10_write_char_attr:
        ; AH=09: Write char+attr at cursor, CX times, no cursor advance
        lda reg_al
        sta io_crtc_reg               ; Save screen code
        lda scr_row
        pha
        lda scr_col
        pha
        ; Get repeat count (cap at 255)
        lda reg_cx+1
        bne _i10wa_cap
        lda reg_cx
        beq _i10wa_restore
        bra _i10wa_go
_i10wa_cap:
        lda #255
_i10wa_go:
        tax
_i10wa_loop:
        ; Write char+attr to guest video buffer
        jsr cwc_calc_vidbuf
        lda reg_al
        ldz #0
        sta [temp_ptr2],z
        lda reg_bl              ; Attribute from BL
        ldz #1
        sta [temp_ptr2],z
        ; Write to MEGA65 screen
        jsr calc_scr_ptr
        lda io_crtc_reg
        ldz #0
        sta [temp_ptr],z
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc +
        lda #0
        sta scr_col
        inc scr_row
+       dex
        bne _i10wa_loop
_i10wa_restore:
        pla
        sta scr_col
        pla
        sta scr_row
        rts

_i10_write_char_only:
        ; AH=0A: Write char only at cursor, CX times, preserve existing attr
        lda reg_al
        sta io_crtc_reg               ; Save screen code
        lda scr_row
        pha
        lda scr_col
        pha
        ; Get repeat count (cap at 255)
        lda reg_cx+1
        bne _i10wo_cap
        lda reg_cx
        beq _i10wo_restore
        bra _i10wo_go
_i10wo_cap:
        lda #255
_i10wo_go:
        tax
_i10wo_loop:
        ; Write char only to guest video buffer (leave attr byte alone)
        jsr cwc_calc_vidbuf
        lda reg_al
        ldz #0
        sta [temp_ptr2],z
        ; Do NOT write attribute — preserve existing byte at z=1
        ; Write to MEGA65 screen
        jsr calc_scr_ptr
        lda io_crtc_reg
        ldz #0
        sta [temp_ptr],z
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc +
        lda #0
        sta scr_col
        inc scr_row
+       dex
        bne _i10wo_loop
_i10wo_restore:
        pla
        sta scr_col
        pla
        sta scr_row
        rts

_i10_write_string:
        ; AH=13: Write string — ES:BP=string, CX=length, DH/DL=row/col
        ; AL bit 0: update cursor after. AL bit 1: string has char+attr pairs
        ; BL=attribute (modes 0/1)
        ; Save mode and original cursor
        lda reg_al
        sta io_save_a               ; Save mode
        lda scr_row
        pha
        lda scr_col
        pha
        ; Set cursor to DH/DL
        lda reg_dh
        sta scr_row
        lda reg_dl
        sta scr_col
        ; Set up pointer to string at ES:BP
        lda reg_bp86
        sta temp32
        lda reg_bp86+1
        sta temp32+1
        ; Read string length
        lda reg_cx
        sta io_save_b               ; Count low
        lda reg_cx+1
        sta io_save_c               ; Count high
_i10ws_loop:
        lda io_save_b
        ora io_save_c
        beq _i10ws_done
        ; Read char from ES:BP
        ldx #SEG_ES_OFS
        jsr mem_read8
        sta io_save_d               ; Save char
        inc temp32
        bne +
        inc temp32+1
+
        ; Check mode bit 1: char+attr pairs?
        lda io_save_a
        and #$02
        beq _i10ws_use_bl
        ; Mode 2/3: read attr from next byte
        ldx #SEG_ES_OFS
        jsr mem_read8
        sta reg_bl              ; Use as attribute
        inc temp32
        bne +
        inc temp32+1
+
_i10ws_use_bl:
        ; Write char via con_write_char (handles screen + vidbuf + cursor advance)
        lda io_save_d
        jsr con_write_char
        ; Decrement count
        lda io_save_b
        bne +
        dec io_save_c
+       dec io_save_b
        bra _i10ws_loop
_i10ws_done:
        ; Check if we should restore cursor (mode bit 0 = 0)
        lda io_save_a
        and #$01
        bne _i10ws_exit         ; Bit 0 set: leave cursor at final position
        ; Restore original cursor
        pla
        sta scr_col
        pla
        sta scr_row
        jsr cursor_update
        rts
_i10ws_exit:
        ; Discard saved cursor
        pla
        pla
        jsr cursor_update
        rts

_i10_get_mode:
        ; AH=0F: Get current video mode — read from BDA 40:49
        ; AL=mode, AH=columns(80), BH=page(0)
        lda #$49
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda [temp_ptr],z
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
        ; Sync cursor from BDA (native mode updates BDA but not scr_row/scr_col)
        lda #$50
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda [temp_ptr],z
        sta scr_col
        ldz #1
        lda [temp_ptr],z
        sta scr_row
        jsr cursor_update
        ; Ensure cursor is visible when waiting for input
        lda #$01
        sta $D015               ; Enable sprite 0
_i16_poll:
        lda $D610               ; Read ASCII key from hardware queue
        bne _i16_got_key
        ; No key — refresh screen if native mode (fast_console off)
        lda fast_console_flag
        bne _i16_poll           ; Fast mode, just poll again
        ; Check if a new frame has elapsed
        lda $D7FA
        cmp last_frame_ctr
        beq _i16_poll           ; Same frame, poll again
        sta last_frame_ctr               ; Update frame counter
        inc sub_frame_ctr
        lda sub_frame_ctr
        cmp #3
        bcc _i16_poll           ; Not time for tick yet
        lda #0
        sta sub_frame_ctr
        ; Clear screen RAM before refresh
        lda #$00
        sta $D707
        .byte $80, $00
        .byte $81, $00
        .byte $00
        .byte $03               ; FILL
        .word 2000              ; 80x25
        .word $0020             ; Space
        .byte $00
        .word $0800             ; Screen RAM
        .byte $00
        .byte $00, $00, $00
        ; Do screen refresh
        jsr refresh_cga
        ; Cursor blink
        lda cursor_hidden
        bne _i16_poll
        inc cursor_blink_ctr
        lda cursor_blink_ctr
        cmp #5
        bcc _i16_poll
        lda #0
        sta cursor_blink_ctr
        lda $D015
        eor #$01
        sta $D015
        bra _i16_poll
_i16_got_key:
        cmp #$09                ; TAB key? (reserved for menu)
        bne +
        sta $D610               ; Dequeue the TAB
        jmp menu_tab_handler    ; Go to menu
+       sta $D610               ; Dequeue the event (write any value)
        ; Check for Ctrl-C (ASCII $03)
        cmp #$03
        bne _i16_not_ctrlc
        ; Set Ctrl-C flag for DOS to check
        lda #1
        sta ctrlc_pending
        ; Return Ctrl-C as the key (AL=0x03, AH=0x2E scancode)
        lda #$03
        sta reg_al
        lda #$2E
        sta reg_ah
        rts
_i16_not_ctrlc:
        ; Map MEGA65 key codes to IBM PC codes
        cmp #$14                ; MEGA65 DELETE/backspace (PETSCII DEL)
        beq _i16_bs
        cmp #$7F                ; ASCII DEL
        beq _i16_bs
        cmp #$91                ; PETSCII cursor up
        beq _i16_up
        cmp #$11                ; PETSCII cursor down
        beq _i16_down
        cmp #$9D                ; PETSCII cursor left
        beq _i16_left
        cmp #$1D                ; PETSCII cursor right
        beq _i16_right
        cmp #$0D                ; Return key
        beq _i16_return
        cmp #$A3                ; PETSCII £ → backslash \
        bne +
        lda #$5C                ; ASCII backslash
+       ; A = ASCII key code
        sta reg_al
        lda #$00
        sta reg_ah
        rts
_i16_bs:
        lda #$08
        sta reg_al
        lda #$0E
        sta reg_ah
        rts
_i16_return:
        lda #$0D
        sta reg_al
        lda #$1C
        sta reg_ah
        rts
_i16_up:
        lda #$00
        sta reg_al
        lda #$48
        sta reg_ah
        rts
_i16_down:
        lda #$00
        sta reg_al
        lda #$50
        sta reg_ah
        rts
_i16_left:
        lda #$00
        sta reg_al
        lda #$4B
        sta reg_ah
        rts
_i16_right:
        lda #$00
        sta reg_al
        lda #$4D
        sta reg_ah
        rts

_i16_check_key:
        ; AH=01: Non-blocking check.
        ; Peek at hardware typing queue — don't dequeue
        lda $D610               ; Read ASCII key from hardware queue
        beq _i16_no_key         ; $00 = no key
        cmp #$09                ; TAB key? (reserved for menu)
        beq _i16_no_key         ; Hide TAB from guest
        ; Check Ctrl-C on peek too
        cmp #$03
        bne _i16ck_not_ctrlc
        lda #$03
        sta reg_al
        lda #$2E
        sta reg_ah
        lda #0
        sta flag_zf             ; ZF=0 = key available
        rts
_i16ck_not_ctrlc:
        ; Map MEGA65 key codes for peek
        cmp #$14
        beq _i16ck_bs
        cmp #$7F
        beq _i16ck_bs
        cmp #$91
        beq _i16ck_up
        cmp #$11
        beq _i16ck_down
        cmp #$9D
        beq _i16ck_left
        cmp #$1D
        beq _i16ck_right
        cmp #$0D
        beq _i16ck_return
        cmp #$A3                ; PETSCII £ → backslash \
        bne +
        lda #$5C
+       sta reg_al
        lda #$00
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_bs:
        lda #$08
        sta reg_al
        lda #$0E
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_return:
        lda #$0D
        sta reg_al
        lda #$1C
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_up:
        lda #$00
        sta reg_al
        lda #$48
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_down:
        lda #$00
        sta reg_al
        lda #$50
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_left:
        lda #$00
        sta reg_al
        lda #$4B
        sta reg_ah
        lda #0
        sta flag_zf
        rts
_i16ck_right:
        lda #$00
        sta reg_al
        lda #$4D
        sta reg_ah
        lda #0
        sta flag_zf
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
        jmp cursor_update

_cs_cr:
        lda #0
        sta scr_col
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       jmp cursor_update

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
        jmp cursor_update

_cs_down:
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       jmp cursor_update

_cs_right:
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc +
        lda #SCR_COLS-1
        sta scr_col
+       jmp cursor_update

_cs_left:
        lda scr_col
        beq +
        dec scr_col
+       jmp cursor_update

_cs_home:
        lda #0
        sta scr_row
        sta scr_col
        jmp cursor_update

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

; ============================================================================
; do_clear_window — Clear a rectangular region in vidbuf
; ============================================================================
; Input: reg_ch=top row, reg_cl=left col, reg_dh=bottom row, reg_dl=right col
;        reg_bh=fill attribute
; Clears vidbuf at $18000 (char+attr pairs, 160 bytes/row)
;
do_clear_window:
        lda reg_ch
        sta scr_clear_row               ; Current row

_dcw_row_loop:
        lda scr_clear_row
        sta $D770
        lda #0
        sta $D771
        lda #80
        sta $D774
        lda #0
        sta $D775
        clc
        lda $D778
        adc reg_cl
        sta scratch_a
        lda $D779
        adc #0
        sta scratch_b
        asl scratch_a
        rol scratch_b
        lda scratch_a
        sta temp_ptr2
        lda scratch_b
        clc
        adc #$80
        sta temp_ptr2+1
        lda #$01
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3

        sec
        lda reg_dl
        sbc reg_cl
        sta scratch_c
        inc scratch_c

        ldx scratch_c
        ldz #0
_dcw_col_loop:
        lda #$20
        sta [temp_ptr2],z
        inz
        lda reg_bh
        sta [temp_ptr2],z
        inz
        dex
        bne _dcw_col_loop

        lda scr_clear_row
        cmp reg_dh
        bcs _dcw_done
        inc scr_clear_row
        bra _dcw_row_loop
_dcw_done:
        rts

; ============================================================================
; do_clear_window_scr — Clear rectangle in MEGA65 screen RAM ($0800)
; ============================================================================
; Same window coords as do_clear_window: reg_ch/cl/dh/dl
; Writes space ($20) to screen RAM (1 byte per cell, no attributes)
;
do_clear_window_scr:
        lda reg_ch
        sta scr_clear_row_s               ; Current row

_dcws_row_loop:
        ; Compute screen offset = row * 80 + col
        lda scr_clear_row_s
        sta $D770
        lda #0
        sta $D771
        lda #80
        sta $D774
        lda #0
        sta $D775
        clc
        lda $D778
        adc reg_cl
        sta scratch_a
        lda $D779
        adc #0
        sta scratch_b
        ; Add SCREEN_BASE ($0800)
        clc
        lda scratch_a
        adc #<SCREEN_BASE
        sta temp_ptr2
        lda scratch_b
        adc #>SCREEN_BASE
        sta temp_ptr2+1
        lda #$00
        sta temp_ptr2+2
        sta temp_ptr2+3

        sec
        lda reg_dl
        sbc reg_cl
        sta scratch_c
        inc scratch_c

        ldx scratch_c
        ldz #0
_dcws_col_loop:
        lda #$20
        sta [temp_ptr2],z
        inz
        dex
        bne _dcws_col_loop

        lda scr_clear_row_s
        cmp reg_dh
        bcs _dcws_done
        inc scr_clear_row_s
        bra _dcws_row_loop
_dcws_done:
        rts

; --- Scroll screen up one line via DMA ---
do_scr_scroll:
        lda scr_row
        cmp #SCR_ROWS
        bcc do_scr_scroll_done     ; Not past bottom, no scroll needed

        ; === Scroll MEGA65 screen ($0800) ===
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

        ; === Scroll guest video buffer ($18000, bank 1) ===
        ; 160 bytes/row (80 chars × 2 bytes each: char + attr)
        ; DMA copy: row 1-24 → row 0-23 (3840 bytes = 24*160)
        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81, $00          ; Dest MB = 0
        .byte $00               ; End options
        .byte $00               ; Command = COPY
        .word 3840              ; Count = 24 * 160
        .word $80A0             ; Source = $18000 + 160 (row 1)
        .byte $01               ; Source bank 1
        .word $8000             ; Dest = $18000 (row 0)
        .byte $01               ; Dest bank 1
        .byte $00, $00, $00     ; Modulo
        ; Clear last row of video buffer (80 char+attr pairs)
        lda #<($8000+3840)      ; $8F00
        sta temp_ptr2
        lda #>($8000+3840)      ; $8F
        sta temp_ptr2+1
        lda #$01
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3
        ldx #80
_scr_scroll_vbuf_clr:
        lda #$20                ; Space character
        ldz #0
        sta [temp_ptr2],z
        lda #CON_ATTR           ; Default attribute ($07)
        ldz #1
        sta [temp_ptr2],z
        clc
        lda temp_ptr2
        adc #2
        sta temp_ptr2
        bcc +
        inc temp_ptr2+1
+       dex
        bne _scr_scroll_vbuf_clr

        lda #SCR_ROWS-1
        sta scr_row             ; Cursor on last row
do_scr_scroll_done:
        rts

; ============================================================================
; do_scr_scroll_down — Scroll screen DOWN one line
; ============================================================================
; Moves rows 0-23 down to rows 1-24, clears row 0.
; Scrolls both MEGA65 screen and guest video buffer.
;
do_scr_scroll_down:
        ; === Scroll MEGA65 screen DOWN ===
        ; Copy rows 0-23 down to rows 1-24 (1920 bytes, one row at a time)
        ; Work from bottom to top to avoid overlap corruption
        ldx #24                 ; 24 rows to copy
        lda #<(SCREEN_BASE+1920) ; Start at row 24 dest
        sta dma_dst_lo
        lda #>(SCREEN_BASE+1920)
        sta dma_dst_hi
        lda #<(SCREEN_BASE+1840) ; Source = row 23
        sta dma_src_lo
        lda #>(SCREEN_BASE+1840)
        sta dma_src_hi
_ssd_scr_loop:
        lda #$00
        sta dma_src_bank
        sta dma_dst_bank
        lda #SCR_COLS
        sta dma_count_lo
        lda #$00
        sta dma_count_hi
        jsr do_dma_chip_copy
        ; Move source and dest up one row (subtract 80)
        sec
        lda dma_dst_lo
        sbc #SCR_COLS
        sta dma_dst_lo
        lda dma_dst_hi
        sbc #0
        sta dma_dst_hi
        sec
        lda dma_src_lo
        sbc #SCR_COLS
        sta dma_src_lo
        lda dma_src_hi
        sbc #0
        sta dma_src_hi
        dex
        bne _ssd_scr_loop
        ; Clear top row
        lda #$00
        sta $D707
        .byte $80, $00
        .byte $81, $00
        .byte $00
        .byte $03               ; FILL
        .word SCR_COLS
        .word $0020             ; Space
        .byte $00
        .word SCREEN_BASE       ; Row 0
        .byte $00
        .byte $00, $00, $00

        ; === Scroll guest video buffer DOWN ===
        ; Same approach: one row at a time, bottom to top
        ldx #24
        lda #<($8000+3840)      ; Dest = row 24
        sta dma_dst_lo
        lda #>($8000+3840)
        sta dma_dst_hi
        lda #<($8000+3680)      ; Source = row 23
        sta dma_src_lo
        lda #>($8000+3680)
        sta dma_src_hi
_ssd_vbuf_loop:
        lda #$01
        sta dma_src_bank
        sta dma_dst_bank
        lda #<160
        sta dma_count_lo
        lda #$00
        sta dma_count_hi
        jsr do_dma_chip_copy
        ; Move up one row (subtract 160)
        sec
        lda dma_dst_lo
        sbc #<160
        sta dma_dst_lo
        lda dma_dst_hi
        sbc #>160
        sta dma_dst_hi
        sec
        lda dma_src_lo
        sbc #<160
        sta dma_src_lo
        lda dma_src_hi
        sbc #>160
        sta dma_src_hi
        dex
        bne _ssd_vbuf_loop
        ; Clear top row of video buffer
        lda #<$8000
        sta temp_ptr2
        lda #>$8000
        sta temp_ptr2+1
        lda #$01
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3
        ldx #80
_ssd_vbuf_clr:
        lda #$20
        ldz #0
        sta [temp_ptr2],z
        lda #CON_ATTR
        ldz #1
        sta [temp_ptr2],z
        clc
        lda temp_ptr2
        adc #2
        sta temp_ptr2
        bcc +
        inc temp_ptr2+1
+       dex
        bne _ssd_vbuf_clr
        rts

; ============================================================================
; clear_vidbuf — Clear entire guest video buffer
; ============================================================================
clear_vidbuf:
        lda #<$8000
        sta temp_ptr2
        lda #>$8000
        sta temp_ptr2+1
        lda #$01
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3
        ldx #0                  ; 256 iterations × 8 passes = 2048 cells (covers 80x25=2000)
        ldy #8                  ; 8 passes of 256
_cv_outer:
_cv_loop:
        lda #$20
        ldz #0
        sta [temp_ptr2],z
        lda #CON_ATTR
        ldz #1
        sta [temp_ptr2],z
        clc
        lda temp_ptr2
        adc #2
        sta temp_ptr2
        bcc +
        inc temp_ptr2+1
+       dex
        bne _cv_loop
        dey
        bne _cv_outer
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

; ============================================================================
; Console Renderer — single source of truth for DOS text output
; ============================================================================
VIDBUF_BASE     = $018000       ; Bank 1: guest video buffer (char+attr pairs)
CON_ATTR        = $07           ; Default attribute: white on black

; ============================================================================
; con_write_char — Write one ASCII character to console
; ============================================================================
; Input: A = ASCII character
;
con_write_char:
        cmp #$0D
        beq _cwc_cr
        cmp #$0A
        beq _cwc_lf
        cmp #$08
        beq _cwc_bs
        cmp #$09
        beq _cwc_tab
        cmp #$07
        beq _cwc_bel
        cmp #$20
        bcc _cwc_done           ; Other control chars — ignore

        ; --- Printable character ---
        ; DEBUG: save row/col/char to scr_disarm (if scr_disarm == $FF)
        pha
        lda scr_disarm
        cmp #$FF
        bne _cwc_no_dbg
        pla
        pha
        sta scr_save_char               ; Character
        lda scr_row
        sta scr_save_row               ; Row
        lda scr_col
        sta scr_save_col               ; Col
        lda #$00
        sta scr_disarm               ; Disarm
_cwc_no_dbg:

        ; Write to guest text page
        jsr cwc_calc_vidbuf
        pla
        pha
        ldz #0
        sta [temp_ptr2],z
        lda #CON_ATTR
        ldz #1
        sta [temp_ptr2],z

        ; Write to MEGA65 screen (CP437 font: ASCII = screen code)
        jsr calc_scr_ptr
        pla
        ldz #0
        sta [temp_ptr],z

        ; Advance cursor
        inc scr_col
        lda scr_col
        cmp #SCR_COLS
        bcc _cwc_done
        lda #0
        sta scr_col
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc _cwc_done
        jsr do_scr_scroll
_cwc_done:
        jmp cursor_update

_cwc_cr:
        ; Carriage return: column 0 only, no row advance
        lda #0
        sta scr_col
        jmp cursor_update

_cwc_lf:
        ; Line feed: advance row
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       jmp cursor_update

_cwc_bs:
        lda scr_col
        beq _cwc_done
        dec scr_col
        jsr calc_scr_ptr
        lda #$20
        ldz #0
        sta [temp_ptr],z
        jsr cwc_calc_vidbuf
        lda #$20
        ldz #0
        sta [temp_ptr2],z
        lda #CON_ATTR
        ldz #1
        sta [temp_ptr2],z
        jmp cursor_update

_cwc_tab:
        lda scr_col
        ora #$07
        inc a
        cmp #SCR_COLS
        bcc _cwc_tab_ok
        lda #0
        sta scr_col
        inc scr_row
        lda scr_row
        cmp #SCR_ROWS
        bcc +
        jsr do_scr_scroll
+       jmp cursor_update
_cwc_tab_ok:
        sta scr_col
        jmp cursor_update

_cwc_bel:
        rts

; Calculate guest video buffer pointer
; Output: temp_ptr2 = VIDBUF_BASE + (row*80+col)*2
cwc_calc_vidbuf:
        lda scr_row
        asl
        asl
        asl
        asl
        sta scratch_a
        lda scr_row
        lsr
        lsr
        lsr
        lsr
        sta scratch_b
        lda scr_row
        asl
        asl
        asl
        asl
        asl
        asl
        sta scratch_c
        lda scr_row
        lsr
        lsr
        sta scratch_d
        clc
        lda scratch_a
        adc scratch_c
        sta scratch_a
        lda scratch_b
        adc scratch_d
        sta scratch_b
        clc
        lda scratch_a
        adc scr_col
        sta scratch_a
        lda scratch_b
        adc #0
        sta scratch_b
        asl scratch_a
        rol scratch_b
        clc
        lda scratch_a
        adc #<VIDBUF_BASE
        sta temp_ptr2
        lda scratch_b
        adc #>VIDBUF_BASE
        sta temp_ptr2+1
        lda #$01
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3
        rts

; con_write_buffer removed — was dead code due to unresolved cache
; coherency issue. AH=40h now handled by DOS natively.

; ============================================================================
; Sprite cursor — uses sprite 0 as a blinking text cursor
; ============================================================================
; (con_write_buffer function removed — dead code, cache coherency issue)
; ============================================================================
; Sprite cursor — uses sprite 0 as a blinking text cursor
; ============================================================================
; VIC-IV sprite 0 registers:
;   $D000 = sprite 0 X low
;   $D001 = sprite 0 Y
;   $D010 = sprite X MSB (bit 0 = sprite 0)
;   $D015 = sprite enable (bit 0 = sprite 0)
;   $D027 = sprite 0 color
;   $D01C = sprite multicolor (bit 0 = 0 for hires)
;   $D017 = sprite Y expand
;   $D01D = sprite X expand
;   Sprite pointer at SCREEN_BASE + $3F8 (sprite 0)
;
; 80-col mode character cell: 8x8 pixels
; Screen origin approximately X=80, Y=50 (may need tuning)

CURSOR_X_OFS    = 80            ; X pixel offset to column 0
CURSOR_Y_OFS    = 37            ; Y pixel offset to row 0
CURSOR_COLOR    = 5             ; Green

; ============================================================================
; cursor_init — Set up sprite 0 as text cursor
; ============================================================================
cursor_init:
        ; Set up sprite shape: underscore cursor (scan lines 6-7)
        jsr cursor_set_underline

        ; Set up SPRPTRADR to point to our sprite pointer table
        ; Table at cursor_spr_ptrs (16-byte aligned)
        ; $D06C = low byte, $D06D = high byte, $D06E bit 7 = SPRPTR16
        lda #<cursor_spr_ptrs
        sta $D06C
        lda #>cursor_spr_ptrs
        sta $D06D
        lda $D06E
        ora #$80                ; Set SPRPTR16 bit
        sta $D06E

        ; Write 16-bit sprite pointer for sprite 0
        ; Pointer value = cursor_sprite_data / 64
        ; Split into low byte at cursor_spr_ptrs+0, high at cursor_spr_ptrs+1
        lda #<(cursor_sprite_data / 64)
        sta cursor_spr_ptrs
        lda #>(cursor_sprite_data / 64)
        sta cursor_spr_ptrs+1

        ; Configure sprite 0
        lda #CURSOR_COLOR
        sta $D027               ; Sprite 0 color
        lda #$00
        sta $D01C               ; Not multicolor
        sta $D017               ; No Y expand
        sta $D01D               ; No X expand
        ; Enable H640 sprite X positioning (needed for X >= 512)
        lda $D054
        ora #$10                ; SPRH640
        sta $D054

        lda #$01
        sta $D015               ; Enable sprite 0

        ; Reset blink state
        lda #0
        sta cursor_blink_ctr               ; Blink counter
        sta cursor_hidden               ; Cursor hidden flag

        ; Position cursor at scr_row/scr_col
        jsr cursor_update
        rts

; ============================================================================
; cursor_update — Move sprite to current scr_row/scr_col position
; ============================================================================
cursor_update:
        ; X = CURSOR_X_OFS + scr_col * 8
        ; Need:
        ;   $D000      = X bits 7..0
        ;   $D010 bit0 = X bit 8
        ;   $D05F bit0 = X bit 9   (MEGA65 H640 sprite mode)

        lda scr_col
        sta $D770               ; Multiplier A byte 0
        lda #0
        sta $D771               ; Multiplier A byte 1
        sta $D772               ; Multiplier A byte 2
        sta $D773               ; Multiplier A byte 3

        lda #8
        sta $D774               ; Multiplier B byte 0
        lda #0
        sta $D775               ; Multiplier B byte 1
        sta $D776               ; Multiplier B byte 2
        sta $D777               ; Multiplier B byte 3

        clc
        lda $D778               ; product low
        adc #CURSOR_X_OFS
        sta $D000               ; sprite 0 X low

        lda $D779               ; product high + carry from offset add
        adc #0
        sta scratch_a           ; save X bits 15..8

        ; ---- X bit 8 -> $D010 bit 0 ----
        lda $D010
        and #$FE
        sta $D010
        lda scratch_a
        and #$01
        beq _cu_no_bit8
        lda $D010
        ora #$01
        sta $D010
_cu_no_bit8:

        ; ---- X bit 9 -> $D05F bit 0 ----
        lda $D05F
        and #$FE
        sta $D05F
        lda scratch_a
        and #$02
        beq _cu_y
        lda $D05F
        ora #$01
        sta $D05F

_cu_y:
        ; Y = CURSOR_Y_OFS + scr_row * 8
        lda scr_row
        asl
        asl
        asl
        clc
        adc #CURSOR_Y_OFS
        sta $D001
        ; Sync cursor position to BDA 40:50/51 (keeps BDA in sync for mode switches)
        lda #$50
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda scr_col
        ldz #0
        sta [temp_ptr],z        ; BDA curpos_x (40:50)
        lda scr_row
        ldz #1
        sta [temp_ptr],z        ; BDA curpos_y (40:51)
        rts

; ============================================================================
; cursor_show / cursor_hide
; ============================================================================
cursor_show:
        lda #0
        sta cursor_hidden               ; Clear hidden flag — blink resumes
        lda $D015
        ora #$01
        sta $D015
        rts

cursor_hide:
        lda #1
        sta cursor_hidden               ; Set hidden flag — blink stops
        lda $D015
        and #$FE
        sta $D015
        rts

; ============================================================================
; cursor_set_underline / cursor_set_block — Change sprite shape
; ============================================================================
cursor_set_shape:
        ; Set cursor sprite shape from scan line range
        ; Input: scratch_c = start scan line (0-7), scratch_d = end scan line (0-7)
        ; Maps 8 PC scan lines onto sprite rows 13-20 (bottom 8 of 21)
        ; Clear entire sprite first
        ldx #62
        lda #$00
-       sta cursor_sprite_data,x
        dex
        bpl -
        ; Clamp start/end to 0-7
        lda scratch_c
        cmp #8
        bcc +
        lda #7
+       sta scratch_c
        lda scratch_d
        cmp #8
        bcc +
        lda #7
+       sta scratch_d
        ; Fill rows from start to end (inclusive)
        ; Sprite row = 13 + scan_line, byte offset = row * 3
        lda scratch_c           ; Start scan line
        clc
        adc #13                 ; Map to sprite row
        ; Multiply by 3: row*3 = row*2 + row
        sta scratch_a
        asl                     ; ×2
        clc
        adc scratch_a           ; ×3
        tax                     ; X = byte offset of first row
        lda scratch_d
        sec
        sbc scratch_c           ; End - start
        tay
        iny                     ; Count = end - start + 1
_css_fill:
        lda #$FE                ; 8 pixels wide
        sta cursor_sprite_data,x
        inx
        inx
        inx                     ; Next row (3 bytes per row)
        dey
        bne _css_fill
        rts

cursor_set_underline:
        ; Convenience: set underline (scan lines 6-7)
        lda #6
        sta scratch_c
        lda #7
        sta scratch_d
        jmp cursor_set_shape

; Sprite pointer table (16-byte aligned, 16 bytes for 8 sprites × 2)
        .align 16
cursor_spr_ptrs:
        .fill 16, 0

; Sprite data must be 64-byte aligned
        .align 64
cursor_sprite_data:
        .fill 64, 0

