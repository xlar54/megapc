; ============================================================================
; modrm.asm — ModR/M Decoding & Effective Address Calculation
; ============================================================================
;
; Decodes the ModR/M byte and computes the effective address for
; memory operands. Sets i_mod, i_reg, i_rm, and rm_addr.
;
; ModR/M byte format: [mod:2][reg:3][rm:3]
;
; Effective address modes (16-bit, mod < 3):
;   rm=0: BX+SI    rm=1: BX+DI    rm=2: BP+SI    rm=3: BP+DI
;   rm=4: SI       rm=5: DI       rm=6: BP/disp16 rm=7: BX
;
; mod=0: no displacement (except rm=6 → direct address)
; mod=1: 8-bit signed displacement
; mod=2: 16-bit displacement
; mod=3: register (no memory access)

; ============================================================================
; decode_modrm — Fetch and decode ModR/M byte
; ============================================================================
; Fetches the ModR/M byte from CS:IP, extracts mod/reg/rm fields,
; and computes effective address if mod < 3.
;
decode_modrm:
        jsr fetch_byte          ; A = ModR/M byte

        ; Extract fields
        pha
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        sta i_mod               ; mod = bits 7–6

        pla
        pha
        lsr
        lsr
        lsr
        and #$07
        sta i_reg               ; reg = bits 5–3

        pla
        and #$07
        sta i_rm                ; rm = bits 2–0

        ; If mod == 3, operand is register — no EA needed
        lda i_mod
        cmp #3
        beq _dm_reg_mode

        ; Compute effective address based on rm field
        jsr compute_ea
        rts

_dm_reg_mode:
        ; Register operand: rm_addr points to register in ZP
        ; rm field selects the register (0–7)
        ; For byte ops: AL,CL,DL,BL,AH,CH,DH,BH
        ; For word ops: AX,CX,DX,BX,SP,BP,SI,DI
        ; We store the ZP address of the register in rm_addr
        lda i_w
        beq _dm_byte_reg
        ; Word register
        lda i_rm
        asl                     ; ×2 (each reg is 2 bytes)
        clc
        adc #regs
        sta rm_addr
        lda #0
        sta rm_addr+1
        sta rm_addr+2
        sta rm_addr+3
        rts

_dm_byte_reg:
        ; Byte register: 0=AL, 1=CL, 2=DL, 3=BL, 4=AH, 5=CH, 6=DH, 7=BH
        lda i_rm
        cmp #4
        bcs _dm_high_byte
        ; Low byte registers (0–3): AL, CL, DL, BL = regs+0, +2, +4, +6
        asl                     ; ×2
        clc
        adc #regs
        sta rm_addr
        bra _dm_byte_done
_dm_high_byte:
        ; High byte registers (4–7): AH, CH, DH, BH = regs+1, +3, +5, +7
        sec
        sbc #4                  ; 0..3
        asl                     ; 0,2,4,6
        clc
        adc #regs               ; regs+0, +2, +4, +6
        inc a                   ; regs+1, +3, +5, +7 = AH, CH, DH, BH
        sta rm_addr
_dm_byte_done:
        lda #0
        sta rm_addr+1
        sta rm_addr+2
        sta rm_addr+3
        rts

; ============================================================================
; compute_ea — Calculate effective address for memory operands
; ============================================================================
; Input:  i_mod, i_rm set from ModR/M byte
; Output: rm_addr = 20-bit linear address (then mapped to chip)
;
; Default segment: DS for most, SS for BP-based addressing
;
compute_ea:
        ; Start with base register(s) based on rm field
        lda #0
        sta rm_addr             ; Clear EA
        sta rm_addr+1

        lda i_rm
        asl
        tax
        jmp (ea_mode_tbl,x)

ea_mode_tbl:
        .word ea_bx_si          ; rm=0
        .word ea_bx_di          ; rm=1
        .word ea_bp_si          ; rm=2
        .word ea_bp_di          ; rm=3
        .word ea_si             ; rm=4
        .word ea_di             ; rm=5
        .word ea_bp_direct      ; rm=6
        .word ea_bx             ; rm=7

ea_bx_si:
        clc
        lda reg_bx
        adc reg_si
        sta rm_addr
        lda reg_bx+1
        adc reg_si+1
        sta rm_addr+1
        jmp ea_add_disp

ea_bx_di:
        clc
        lda reg_bx
        adc reg_di
        sta rm_addr
        lda reg_bx+1
        adc reg_di+1
        sta rm_addr+1
        jmp ea_add_disp

ea_bp_si:
        clc
        lda reg_bp86
        adc reg_si
        sta rm_addr
        lda reg_bp86+1
        adc reg_si+1
        sta rm_addr+1
        ; Default segment = SS for BP-based
        lda seg_override_en
        bne ea_add_disp
        lda #SEG_SS_OFS
        sta seg_override
        lda #1
        sta seg_override_en
        jmp ea_add_disp

ea_bp_di:
        clc
        lda reg_bp86
        adc reg_di
        sta rm_addr
        lda reg_bp86+1
        adc reg_di+1
        sta rm_addr+1
        ; Default segment = SS for BP-based
        lda seg_override_en
        bne ea_add_disp
        lda #SEG_SS_OFS
        sta seg_override
        lda #1
        sta seg_override_en
        jmp ea_add_disp

ea_si:
        lda reg_si
        sta rm_addr
        lda reg_si+1
        sta rm_addr+1
        jmp ea_add_disp

ea_di:
        lda reg_di
        sta rm_addr
        lda reg_di+1
        sta rm_addr+1
        jmp ea_add_disp

ea_bp_direct:
        ; mod=0, rm=6: direct 16-bit address (no BP)
        lda i_mod
        bne _ea_bp_mode
        ; Direct address: fetch 16-bit displacement as address
        jsr fetch_word
        sta rm_addr
        lda scratch_a
        sta rm_addr+1
        jmp ea_resolve_seg

_ea_bp_mode:
        ; mod=1 or 2 with rm=6: BP + displacement
        lda reg_bp86
        sta rm_addr
        lda reg_bp86+1
        sta rm_addr+1
        ; Default segment = SS
        lda seg_override_en
        bne ea_add_disp
        lda #SEG_SS_OFS
        sta seg_override
        lda #1
        sta seg_override_en
        jmp ea_add_disp

ea_bx:
        lda reg_bx
        sta rm_addr
        lda reg_bx+1
        sta rm_addr+1
        ; Fall through to ea_add_disp

; --- Add displacement based on mod ---
ea_add_disp:
        lda i_mod
        beq ea_resolve_seg      ; mod=0: no displacement

        cmp #1
        beq _ea_disp8

        ; mod=2: 16-bit displacement
        jsr fetch_word
        clc
        adc rm_addr
        sta rm_addr
        lda scratch_a
        adc rm_addr+1
        sta rm_addr+1
        jmp ea_resolve_seg

_ea_disp8:
        ; mod=1: 8-bit signed displacement
        jsr fetch_byte
        ; Sign extend A to 16 bits
        ldx #0
        cmp #$80
        bcc +
        ldx #$FF                ; Negative: extend with $FF
+       clc
        adc rm_addr
        sta rm_addr
        txa
        adc rm_addr+1
        sta rm_addr+1
        ; Fall through

; --- Convert segment:offset EA to linear address ---
ea_resolve_seg:
        ; Save the 16-bit offset BEFORE segment mapping (needed by LEA)
        lda rm_addr
        sta ea_offset_lo
        lda rm_addr+1
        sta ea_offset_hi

        ; rm_addr+0/+1 = 16-bit offset
        ; Default segment is DS unless overridden
        lda rm_addr
        sta temp32
        lda rm_addr+1
        sta temp32+1
        ldx #SEG_DS_OFS         ; Default segment
        jsr seg_ofs_to_linear   ; Handles override internally
        ; temp32 now has 20-bit linear address
        jsr linear_to_chip      ; temp_ptr now has chip address
        lda temp_ptr
        sta rm_addr
        lda temp_ptr+1
        sta rm_addr+1
        lda temp_ptr+2
        sta rm_addr+2
        lda temp_ptr+3
        sta rm_addr+3
        rts

; ============================================================================
; read_rm / write_rm — Access operand via rm_addr
; ============================================================================
; For mod=3 (register), rm_addr is a ZP address.
; For mod<3 (memory), rm_addr is a 32-bit chip/cache address.

; read_rm8 — Read byte from rm operand
; Output: A = byte
read_rm8:
        lda i_mod
        cmp #3
        beq _rrm8_reg
        ; Memory: use [rm_addr],z
        ldz #0
        lda [rm_addr],z
        rts
_rrm8_reg:
        ldx rm_addr             ; ZP address
        lda 0,x
        rts

; read_rm16 — Read word from rm operand
; Output: op_source+0/+1
read_rm16:
        lda i_mod
        cmp #3
        beq _rrm16_reg
        ldz #0
        lda [rm_addr],z
        sta op_source

        ; Check for segment wrap: EA offset was $FFFF
        lda ea_offset_lo
        and ea_offset_hi
        cmp #$FF
        beq _rrm16_seg_wrap

        ; Check page boundary crossing
        lda temp32
        cmp #$FF
        beq _rrm16_cross
_rrm16_no_cross:
        ldz #1
        lda [rm_addr],z
        sta op_source+1
        rts
_rrm16_cross:
        ; Save temp32, resolve next byte, restore
        lda temp32+1
        sta scratch_a
        lda temp32+2
        sta scratch_b
        inc temp32+1
        bne +
        inc temp32+2
+       jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_source+1
        ; Restore temp32 so write_rm16 sees original address
        lda #$FF
        sta temp32
        lda scratch_a
        sta temp32+1
        lda scratch_b
        sta temp32+2
        rts
_rrm16_seg_wrap:
        ; EA offset was $FFFF — second byte wraps to offset $0000 in same segment
        ; Save temp32 for restore
        lda temp32+1
        sta scratch_a
        lda temp32+2
        sta scratch_b
        ; Resolve segment:$0000
        lda #0
        sta temp32
        sta temp32+1
        ldx #SEG_DS_OFS         ; Default segment (seg_ofs_to_linear handles override)
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_source+1
        ; Restore temp32
        lda #$FF
        sta temp32
        lda scratch_a
        sta temp32+1
        lda scratch_b
        sta temp32+2
        rts
_rrm16_reg:
        ldx rm_addr
        lda 0,x
        sta op_source
        lda 1,x
        sta op_source+1
        rts

; write_rm8 — Write byte A to rm operand
write_rm8:
        pha
        lda i_mod
        cmp #3
        beq _wrm8_reg
        pla
        ldz #0
        sta [rm_addr],z
        ; Mark cache dirty if rm_addr is in cache buffer (bank 0)
        lda rm_addr+2
        bne +
        lda rm_addr+1
        sec
        sbc #>CACHE_BUF
        tax
        lda #1
        sta cache_dirty,x
        jsr invalidate_code_cache_for_line
+       rts
_wrm8_reg:
        pla
        ldx rm_addr
        sta 0,x
        rts

; write_rm16 — Write op_result+0/+1 to rm operand
write_rm16:
        lda i_mod
        cmp #3
        beq _wrm16_reg
        lda op_result
        ldz #0
        sta [rm_addr],z
        ; Mark cache dirty if in cache buffer
        lda rm_addr+2
        bne +
        lda rm_addr+1
        sec
        sbc #>CACHE_BUF
        tax
        lda #1
        sta cache_dirty,x
        jsr invalidate_code_cache_for_line
+
        ; Check for segment wrap: EA offset was $FFFF
        lda ea_offset_lo
        and ea_offset_hi
        cmp #$FF
        beq _wrm16_seg_wrap

        ; Check page boundary crossing
        lda temp32
        cmp #$FF
        beq _wrm16_cross
_wrm16_no_cross:
        lda op_result+1
        ldz #1
        sta [rm_addr],z
        rts
_wrm16_cross:
        ; Save temp32 so repeated accesses stay anchored
        lda temp32+1
        sta scratch_a
        lda temp32+2
        sta scratch_b
        inc temp32+1
        bne +
        inc temp32+2
+       jsr linear_to_chip
        lda op_result+1
        ldz #0
        sta [temp_ptr],z
        ; Mark second page dirty
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       ; Restore temp32
        lda #$FF
        sta temp32
        lda scratch_a
        sta temp32+1
        lda scratch_b
        sta temp32+2
        rts
_wrm16_seg_wrap:
        ; EA offset was $FFFF — second byte wraps to offset $0000 in same segment
        lda temp32+1
        sta scratch_a
        lda temp32+2
        sta scratch_b
        lda #0
        sta temp32
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        lda op_result+1
        ldz #0
        sta [temp_ptr],z
        ; Mark dirty
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       ; Restore temp32
        lda #$FF
        sta temp32
        lda scratch_a
        sta temp32+1
        lda scratch_b
        sta temp32+2
        rts
_wrm16_reg:
        ldx rm_addr
        lda op_result
        sta 0,x
        lda op_result+1
        sta 1,x
        rts