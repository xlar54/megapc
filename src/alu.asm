; ============================================================================
; alu.asm — ALU Operations & Flag Handling
; ============================================================================
;
; Core ALU ops: ADD, OR, ADC, SBB, AND, SUB, XOR, CMP
; Flag computation after ALU ops.
;
; The ALU sub-operation is determined by extra_field (0–7) for ALU opcodes.
; For 80–83 group, the sub-operation comes from the ModR/M reg field.

; ============================================================================
; alu_dispatch — Execute ALU operation
; ============================================================================
; Input:  op_source, op_dest = operands (byte or word based on i_w)
;         A = ALU sub-op (0=ADD, 1=OR, 2=ADC, 3=SBB, 4=AND, 5=SUB, 6=XOR, 7=CMP)
; Output: op_result = result
;         Flags updated based on set_flags_type
;
alu_dispatch:
        asl
        tax
        jmp (alu_op_tbl,x)

alu_op_tbl:
        .word alu_add           ; 0 = ADD
        .word alu_or            ; 1 = OR
        .word alu_adc           ; 2 = ADC
        .word alu_sbb           ; 3 = SBB
        .word alu_and           ; 4 = AND
        .word alu_sub           ; 5 = SUB
        .word alu_xor           ; 6 = XOR
        .word alu_cmp           ; 7 = CMP

; --- ADD ---
alu_add:
        clc
        lda op_dest
        adc op_source
        sta op_result
        lda op_dest+1
        adc op_source+1
        sta op_result+1
        jmp set_flags_arith

; --- OR ---
alu_or:
        lda op_dest
        ora op_source
        sta op_result
        lda op_dest+1
        ora op_source+1
        sta op_result+1
        ; OR clears CF and OF
        lda #0
        sta flag_cf
        sta flag_of
        jmp set_flags_logic

; --- ADC ---
alu_adc:
        lda flag_cf
        beq _adc_no_c
        sec
        bra _adc_go
_adc_no_c:
        clc
_adc_go:
        lda op_dest
        adc op_source
        sta op_result
        lda op_dest+1
        adc op_source+1
        sta op_result+1
        jmp set_flags_arith

; --- SBB ---
alu_sbb:
        lda flag_cf
        beq _sbb_no_c
        sec
        bra _sbb_go
_sbb_no_c:
        clc
_sbb_go:
        ; SBB: dest - source - CF (note: 6502 SEC means no borrow)
        ; We need to invert the carry sense
        lda flag_cf
        eor #1
        beq _sbb_sec
        clc
        bra _sbb_do
_sbb_sec:
        sec
_sbb_do:
        lda op_dest
        sbc op_source
        sta op_result
        lda op_dest+1
        sbc op_source+1
        sta op_result+1
        jmp set_flags_arith

; --- AND ---
alu_and:
        lda op_dest
        and op_source
        sta op_result
        lda op_dest+1
        and op_source+1
        sta op_result+1
        lda #0
        sta flag_cf
        sta flag_of
        jmp set_flags_logic

; --- SUB ---
alu_sub:
        sec
        lda op_dest
        sbc op_source
        sta op_result
        lda op_dest+1
        sbc op_source+1
        sta op_result+1
        jmp set_flags_arith

; --- XOR ---
alu_xor:
        lda op_dest
        eor op_source
        sta op_result
        lda op_dest+1
        eor op_source+1
        sta op_result+1
        lda #0
        sta flag_cf
        sta flag_of
        jmp set_flags_logic

; --- CMP (same as SUB but don't store result) ---
alu_cmp:
        sec
        lda op_dest
        sbc op_source
        sta op_result
        lda op_dest+1
        sbc op_source+1
        sta op_result+1
        jmp set_flags_arith
        ; Note: CMP caller must NOT write result back

; ============================================================================
; Flag Setting
; ============================================================================
; set_flags_arith — Set CF, ZF, SF, OF, PF, AF after arithmetic
; set_flags_logic — Set ZF, SF, PF after logic (CF, OF already cleared)

set_flags_arith:
        ; CF: check carry/borrow
        ; For ADD/ADC: carry out of MSB
        ; For SUB/SBB/CMP: borrow (inverted carry)
        ; We use the 6502 carry flag state from the last operation
        ; Actually, we need to compute this from the operands
        jsr compute_cf
        jsr compute_af
        ; Fall through to common flags

set_flags_logic:
        ; ZF
        lda i_w
        beq _sf_byte
        ; Word: check both bytes
        lda op_result
        ora op_result+1
        beq _sf_zf_set
        lda #0
        sta flag_zf
        bra _sf_sf
_sf_zf_set:
        lda #1
        sta flag_zf
        bra _sf_sf
_sf_byte:
        lda op_result
        bne +
        lda #1
        sta flag_zf
        bra _sf_sf
+       lda #0
        sta flag_zf

_sf_sf:
        ; SF: check sign bit of result
        lda i_w
        beq _sf_sf_byte
        lda op_result+1
        and #$80
        bra _sf_sf_store
_sf_sf_byte:
        lda op_result
        and #$80
_sf_sf_store:
        beq +
        lda #1
+       sta flag_sf

        ; PF: parity of low byte of result
        ; Use code-segment parity lookup table
        ldx op_result
        lda parity_tbl,x
        sta flag_pf

        rts

; compute_cf — Compute carry flag from arithmetic result
compute_cf:
        ; For ADD: CF = result < source (unsigned overflow)
        ; For SUB/CMP: CF = dest < source (unsigned borrow)
        ; We determine which by checking the ALU sub-op
        ; Simplified: check if result carried past the bit width
        lda i_w
        beq _ccf_byte

        ; Word mode: compare result magnitude
        ; For SUB/CMP (sub-ops 3,5,7): CF = dest < source
        ; For ADD/ADC (sub-ops 0,2): CF = (result < dest) or (result < source)
        lda extra_field
        and #$07
        cmp #5                  ; SUB
        beq _ccf_sub_w
        cmp #7                  ; CMP
        beq _ccf_sub_w
        cmp #3                  ; SBB
        beq _ccf_sub_w

        ; ADD/ADC: carry if result < either operand
        lda op_result+1
        cmp op_dest+1
        bcc _ccf_set            ; result_hi < dest_hi → carry
        bne _ccf_clear
        lda op_result
        cmp op_dest
        bcc _ccf_set
_ccf_clear:
        lda #0
        sta flag_cf
        rts
_ccf_set:
        lda #1
        sta flag_cf
        rts

_ccf_sub_w:
        ; SUB: CF if dest < source (unsigned)
        lda op_dest+1
        cmp op_source+1
        bcc _ccf_set            ; dest_hi < src_hi → borrow
        bne _ccf_clear
        lda op_dest
        cmp op_source
        bcc _ccf_set
        bra _ccf_clear

_ccf_byte:
        ; Byte mode — same logic but only low bytes
        lda extra_field
        and #$07
        cmp #5
        beq _ccf_sub_b
        cmp #7
        beq _ccf_sub_b
        cmp #3
        beq _ccf_sub_b
        ; ADD byte
        lda op_result
        cmp op_dest
        bcc _ccf_set
        bra _ccf_clear
_ccf_sub_b:
        lda op_dest
        cmp op_source
        bcc _ccf_set
        bra _ccf_clear

; compute_af — Auxiliary carry (carry from bit 3)
compute_af:
        lda op_dest
        eor op_source
        eor op_result
        and #$10                ; Bit 4 indicates carry from bit 3
        beq +
        lda #1
+       sta flag_af
        rts

; ============================================================================
; compute_of — Overflow flag for arithmetic
; ============================================================================
; OF = sign of result differs from expected based on operand signs
; For ADD: OF if both operands same sign and result different sign
; For SUB: OF if operands different sign and result sign = source sign
compute_of_arith:
        lda i_w
        beq _cof_byte
        ; Word
        lda op_dest+1
        eor op_source+1
        sta scratch_a           ; Bit 7: operands have different signs?
        lda op_dest+1
        eor op_result+1
        sta scratch_b           ; Bit 7: dest and result have different signs?

        ; For ADD: OF = ~(dest^source) & (dest^result)
        ; For SUB: OF = (dest^source) & (dest^result)
        lda extra_field
        and #$07
        cmp #5
        beq _cof_sub_w
        cmp #7
        beq _cof_sub_w
        cmp #3
        beq _cof_sub_w
        ; ADD
        lda scratch_a
        eor #$FF                ; Invert
        and scratch_b
        bra _cof_store_w
_cof_sub_w:
        lda scratch_a
        and scratch_b
_cof_store_w:
        and #$80
        beq +
        lda #1
+       sta flag_of
        rts

_cof_byte:
        lda op_dest
        eor op_source
        sta scratch_a
        lda op_dest
        eor op_result
        sta scratch_b
        lda extra_field
        and #$07
        cmp #5
        beq _cof_sub_b
        cmp #7
        beq _cof_sub_b
        cmp #3
        beq _cof_sub_b
        lda scratch_a
        eor #$FF
        and scratch_b
        bra _cof_store_b
_cof_sub_b:
        lda scratch_a
        and scratch_b
_cof_store_b:
        and #$80
        beq +
        lda #1
+       sta flag_of
        rts

; ============================================================================
; flags_to_word — Pack 8086 flags into 16-bit FLAGS register word
; ============================================================================
; Output: op_result+0/+1 = FLAGS word
; Bit layout: ----ODIT SZ-A-P-C
;             15..11 10 9 8  7 6 5 4 3 2 1 0
flags_to_word:
        lda #$02                ; Bit 1 always set in 8086
        ora flag_cf             ; Bit 0
        ldx flag_pf
        beq +
        ora #$04                ; Bit 2
+       ldx flag_af
        beq +
        ora #$10                ; Bit 4
+       ldx flag_zf
        beq +
        ora #$40                ; Bit 6
+       ldx flag_sf
        beq +
        ora #$80                ; Bit 7
+       sta op_result

        lda #$00
        ldx flag_tf
        beq +
        ora #$01                ; Bit 8
+       ldx flag_if
        beq +
        ora #$02                ; Bit 9
+       ldx flag_df
        beq +
        ora #$04                ; Bit 10
+       ldx flag_of
        beq +
        ora #$08                ; Bit 11
+       sta op_result+1
        rts

; ============================================================================
; word_to_flags — Unpack 16-bit FLAGS word to individual flag bytes
; ============================================================================
; Input: op_source+0/+1 = FLAGS word
word_to_flags:
        lda op_source
        and #$01
        sta flag_cf
        lda op_source
        and #$04
        beq +
        lda #1
+       sta flag_pf
        lda op_source
        and #$10
        beq +
        lda #1
+       sta flag_af
        lda op_source
        and #$40
        beq +
        lda #1
+       sta flag_zf
        lda op_source
        and #$80
        beq +
        lda #1
+       sta flag_sf

        lda op_source+1
        and #$01
        sta flag_tf
        lda op_source+1
        and #$02
        beq +
        lda #1
+       sta flag_if
        lda op_source+1
        and #$04
        beq +
        lda #1
+       sta flag_df
        lda op_source+1
        and #$08
        beq +
        lda #1
+       sta flag_of
        rts