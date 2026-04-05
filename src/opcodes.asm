; ============================================================================
; opcodes.asm — Opcode Handlers
; ============================================================================
;
; Each handler is entered from the jump table in decode.asm.
; After execution, jump to opcode_done.
;
; Naming convention: op_<name>
; Handlers that don't advance IP (JMP, CALL, RET, INT) set advance_ip=0.

; ============================================================================
; $00 — Conditional Jumps (70–7F)
; ============================================================================
op_cond_jump:
        ; Fetch 8-bit signed displacement
        jsr fetch_byte
        sta i_data0
        ; Sign extend
        ldx #0
        cmp #$80
        bcc +
        ldx #$FF
+       stx i_data0+1

        ; Condition code = raw_opcode & 0x0F
        lda raw_opcode
        and #$0F
        tax

        ; Check condition
        jsr check_condition     ; Returns A=1 if true
        beq _cj_no_jump

        ; Take jump: IP += signed displacement
        clc
        lda reg_ip
        adc i_data0
        sta reg_ip
        lda reg_ip+1
        adc i_data0+1
        sta reg_ip+1
        jsr update_opcode_ptr
_cj_no_jump:
        jmp opcode_done

; check_condition — Test condition code X (0–15)
; Output: A = 1 if condition met, 0 if not
;
; 70 JO   (OF=1)          71 JNO  (OF=0)
; 72 JB   (CF=1)          73 JNB  (CF=0)
; 74 JZ   (ZF=1)          75 JNZ  (ZF=0)
; 76 JBE  (CF=1 or ZF=1)  77 JA   (CF=0 and ZF=0)
; 78 JS   (SF=1)          79 JNS  (SF=0)
; 7A JP   (PF=1)          7B JNP  (PF=0)
; 7C JL   (SF!=OF)        7D JGE  (SF=OF)
; 7E JLE  (ZF=1 or SF!=OF) 7F JG  (ZF=0 and SF=OF)
check_condition:
        ; X = condition code 0–15
        txa
        asl
        tax
        jmp (_cc_tbl,x)

_cc_tbl:
        .word _cc_jo            ; 0
        .word _cc_jno           ; 1
        .word _cc_jb            ; 2
        .word _cc_jnb           ; 3
        .word _cc_jz            ; 4
        .word _cc_jnz           ; 5
        .word _cc_jbe           ; 6
        .word _cc_ja            ; 7
        .word _cc_js            ; 8
        .word _cc_jns           ; 9
        .word _cc_jp            ; A
        .word _cc_jnp           ; B
        .word _cc_jl            ; C
        .word _cc_jge           ; D
        .word _cc_jle           ; E
        .word _cc_jg            ; F

_cc_jo:  lda flag_of
         bne _cc_true
         bra _cc_false
_cc_jno: lda flag_of
         beq _cc_true
         bra _cc_false
_cc_jb:  lda flag_cf
         bne _cc_true
         bra _cc_false
_cc_jnb: lda flag_cf
         beq _cc_true
         bra _cc_false
_cc_jz:  lda flag_zf
         bne _cc_true
         bra _cc_false
_cc_jnz: lda flag_zf
         beq _cc_true
         bra _cc_false
_cc_jbe: lda flag_cf
         bne _cc_true
         lda flag_zf
         bne _cc_true
         bra _cc_false
_cc_ja:  lda flag_cf
         bne _cc_false
         lda flag_zf
         bne _cc_false
         bra _cc_true
_cc_js:  lda flag_sf
         bne _cc_true
         bra _cc_false
_cc_jns: lda flag_sf
         beq _cc_true
         bra _cc_false
_cc_jp:  lda flag_pf
         bne _cc_true
         bra _cc_false
_cc_jnp: lda flag_pf
         beq _cc_true
         bra _cc_false
_cc_jl:  lda flag_sf            ; SF != OF
         eor flag_of
         bne _cc_true
         bra _cc_false
_cc_jge: lda flag_sf            ; SF == OF
         eor flag_of
         beq _cc_true
         bra _cc_false
_cc_jle: lda flag_zf            ; ZF=1 or SF!=OF
         bne _cc_true
         lda flag_sf
         eor flag_of
         bne _cc_true
         bra _cc_false
_cc_jg:  lda flag_zf            ; ZF=0 and SF==OF
         bne _cc_false
         lda flag_sf
         eor flag_of
         beq _cc_true
         bra _cc_false

_cc_true:
         lda #1
         rts
_cc_false:
         lda #0
         rts

; ============================================================================
; $01 — MOV reg, imm8/imm16 (B0–BF)
; ============================================================================
op_mov_reg_imm:
        ; Register = raw_opcode & 0x07
        ; Byte/word: B0–B7 = byte (i_w=0), B8–BF = word (i_w=1)
        lda i_w
        beq _mri_byte

        ; Word: fetch 16-bit immediate
        jsr fetch_word
        sta i_data0
        lda scratch_a
        sta i_data0+1
        ; Store to register (raw_opcode & 7) * 2
        lda raw_opcode
        and #$07
        asl
        tax
        lda i_data0
        sta regs,x
        lda i_data0+1
        sta regs+1,x
        jmp opcode_done

_mri_byte:
        ; Byte: fetch 8-bit immediate
        jsr fetch_byte
        sta i_data0
        ; Register: 0=AL, 1=CL, 2=DL, 3=BL, 4=AH, 5=CH, 6=DH, 7=BH
        lda raw_opcode
        and #$07
        cmp #4
        bcs _mri_high
        ; Low byte register
        asl
        tax
        lda i_data0
        sta regs,x
        jmp opcode_done
_mri_high:
        sec
        sbc #4
        asl
        tax
        lda i_data0
        sta regs+1,x           ; High byte of register pair
        jmp opcode_done

; ============================================================================
; $02 — INC/DEC r16 (40–4F)
; ============================================================================
op_inc_dec_r16:
        lda raw_opcode
        and #$07
        asl
        tax                     ; X = register offset

        ; Load current value
        lda regs,x
        sta op_dest
        lda regs+1,x
        sta op_dest+1

        lda #1
        sta op_source
        lda #0
        sta op_source+1

        ; INC (40–47) or DEC (48–4F)?
        lda raw_opcode
        cmp #$48
        bcs _idr_dec

        ; INC (extra_field = 0 from table → ADD logic for OF)
        clc
        lda op_dest
        adc #1
        sta op_result
        sta regs,x
        lda op_dest+1
        adc #0
        sta op_result+1
        sta regs+1,x
        ; INC/DEC don't affect CF
        jsr set_flags_logic     ; Set ZF, SF, PF
        jsr compute_of_arith   ; Set OF
        jmp opcode_done

_idr_dec:
        ; extra_field = 5 from table → SUB logic for OF
        sec
        lda op_dest
        sbc #1
        sta op_result
        sta regs,x
        lda op_dest+1
        sbc #0
        sta op_result+1
        sta regs+1,x
        jsr set_flags_logic
        jsr compute_of_arith
        jmp opcode_done

; ============================================================================
; $03 — PUSH r16 (50–57)
; ============================================================================
op_push_r16:
        lda raw_opcode
        and #$07
        asl
        tax
        lda regs,x
        sta op_result
        lda regs+1,x
        sta op_result+1
        jsr push_word
        jmp opcode_done

; ============================================================================
; $04 — POP r16 (58–5F)
; ============================================================================
op_pop_r16:
        jsr pop_word            ; Result in op_result
        lda raw_opcode
        and #$07
        asl
        tax
        lda op_result
        sta regs,x
        lda op_result+1
        sta regs+1,x
        jmp opcode_done

; ============================================================================
; $3B — POP r/m16 (8F)
; ============================================================================
op_pop_rm:
        jsr pop_word            ; Result in op_result
        jsr write_rm16          ; Write to r/m destination (already decoded)
        jmp opcode_done

; ============================================================================
; $09 — ALU reg, r/m (00–03, 08–0B, etc.)
; ============================================================================
op_alu_reg_rm:
        ; Read both operands based on i_d
        ; i_d=0: dest=r/m, source=reg
        ; i_d=1: dest=reg, source=r/m
        jsr load_reg_operand   ; Load reg operand
        lda i_w
        beq _arm_byte

        ; Word mode
        jsr read_rm16           ; op_source = r/m value
        lda i_d
        beq _arm_w_rm_dest
        ; reg is dest, r/m is source (already in op_source)
        ; reg value is in op_dest (from load_reg_operand)
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        ; Write result back to reg (unless CMP)
        lda extra_field
        cmp #7                  ; CMP
        beq _arm_done
        jsr store_reg_result
        jmp opcode_done

_arm_w_rm_dest:
        ; r/m is dest, reg is source
        ; Swap: op_dest = r/m, op_source = reg
        lda op_source
        sta scratch_a
        lda op_source+1
        sta scratch_b
        lda op_dest
        sta op_source
        lda op_dest+1
        sta op_source+1
        lda scratch_a
        sta op_dest
        lda scratch_b
        sta op_dest+1
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        lda extra_field
        cmp #7
        beq _arm_done
        jsr write_rm16
_arm_done:
        jmp opcode_done

_arm_byte:
        ; Byte mode — similar but with 8-bit ops
        jsr read_rm8
        sta op_source           ; Temporarily
        lda #0
        sta op_source+1
        lda i_d
        beq _arm_b_rm_dest
        ; reg is dest (already loaded), r/m is source
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        lda extra_field
        cmp #7
        beq _arm_done
        jsr store_reg_result_byte
        jmp opcode_done
_arm_b_rm_dest:
        ; Swap operands
        lda op_source
        pha
        lda op_dest
        sta op_source
        pla
        sta op_dest
        lda #0
        sta op_source+1
        sta op_dest+1
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        lda extra_field
        cmp #7
        beq _arm_done
        lda op_result
        jsr write_rm8
        jmp opcode_done

; --- Helper: Load register operand based on i_reg ---
load_reg_operand:
        lda i_w
        beq _lro_byte
        ; Word: reg = i_reg * 2
        lda i_reg
        asl
        tax
        lda regs,x
        sta op_dest
        lda regs+1,x
        sta op_dest+1
        rts
_lro_byte:
        lda i_reg
        cmp #4
        bcs _lro_high
        asl
        tax
        lda regs,x
        sta op_dest
        lda #0
        sta op_dest+1
        rts
_lro_high:
        sec
        sbc #4
        asl
        tax
        lda regs+1,x
        sta op_dest
        lda #0
        sta op_dest+1
        rts

; --- Helper: Store result to register ---
store_reg_result:
        lda i_reg
        asl
        tax
        lda op_result
        sta regs,x
        lda op_result+1
        sta regs+1,x
        rts

store_reg_result_byte:
        lda i_reg
        cmp #4
        bcs _srb_high
        asl
        tax
        lda op_result
        sta regs,x
        rts
_srb_high:
        sec
        sbc #4
        asl
        tax
        lda op_result
        sta regs+1,x
        rts

; ============================================================================
; $32 — MOV reg,r/m (88–8B)
; ============================================================================
op_mov_reg_rm:
        lda i_d
        beq _mrm_to_rm

        ; --- i_d=1: reg ← r/m ---
        lda i_w
        beq _mrm_r_byte_from_rm
        ; Word: reg ← r/m word
        jsr read_rm16
        lda i_reg
        asl
        tax
        lda op_source
        sta regs,x
        lda op_source+1
        sta regs+1,x
        jmp opcode_done

_mrm_r_byte_from_rm:
        ; Byte: reg ← r/m byte
        jsr read_rm8            ; A = byte value
        pha                     ; Save the byte
        lda i_reg
        cmp #4
        bcs _mrm_rb_hi_from
        ; Low byte reg (0–3)
        asl
        tax
        pla
        sta regs,x
        jmp opcode_done
_mrm_rb_hi_from:
        ; High byte reg (4–7 → AH,CH,DH,BH)
        sec
        sbc #4
        asl
        tax
        pla
        sta regs+1,x
        jmp opcode_done

_mrm_to_rm:
        ; --- i_d=0: r/m ← reg ---
        lda i_w
        beq _mrm_w_byte
        ; Word: r/m ← reg word
        lda i_reg
        asl
        tax
        lda regs,x
        sta op_result
        lda regs+1,x
        sta op_result+1
        jsr write_rm16
        jmp opcode_done
_mrm_w_byte:
        ; Byte: r/m ← reg byte
        lda i_reg
        cmp #4
        bcs _mrm_wb_hi
        asl
        tax
        lda regs,x
        jsr write_rm8
        jmp opcode_done
_mrm_wb_hi:
        sec
        sbc #4
        asl
        tax
        lda regs+1,x
        jsr write_rm8
        jmp opcode_done

; ============================================================================
; $13 — RET / RETF (C2/C3/CA/CB)
; ============================================================================
op_ret:
        ; extra_field determines type:
        ; C3: near RET
        ; C2: near RET imm16 (pop extra bytes)
        ; CB: far RETF
        ; CA: far RETF imm16

        ; For C2 and CA: fetch the imm16 BEFORE popping (IP still valid)
        lda raw_opcode
        cmp #$C2
        beq _ret_fetch_imm
        cmp #$CA
        beq _ret_fetch_imm
        lda #$00
        sta i_data0             ; No extra SP adjustment
        sta i_data0+1
        bra _ret_do_pop
_ret_fetch_imm:
        jsr fetch_word          ; A = low, scratch_a = high
        sta i_data0
        lda scratch_a
        sta i_data0+1

_ret_do_pop:
        jsr pop_word            ; Pop IP
        lda op_result
        sta reg_ip
        lda op_result+1
        sta reg_ip+1

        ; Check if far return (CA, CB)
        lda raw_opcode
        cmp #$CA
        beq _ret_far
        cmp #$CB
        beq _ret_far

        ; Near return — apply imm16 SP adjustment (0 for C3)
        clc
        lda reg_sp86
        adc i_data0
        sta reg_sp86
        lda reg_sp86+1
        adc i_data0+1
        sta reg_sp86+1

_ret_done:
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

_ret_far:
        ; Pop CS
        jsr pop_word
        lda op_result
        sta reg_cs
        lda op_result+1
        sta reg_cs+1
        lda #1
        sta cs_dirty

        ; Apply imm16 SP adjustment (0 for CB)
        clc
        lda reg_sp86
        adc i_data0
        sta reg_sp86
        lda reg_sp86+1
        adc i_data0+1
        sta reg_sp86+1

        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

; ============================================================================
; $34 — IRET (CF)
; ============================================================================
op_int_ret:
        ; Pop IP, CS, FLAGS
        jsr pop_word
        lda op_result
        sta reg_ip
        lda op_result+1
        sta reg_ip+1

        jsr pop_word
        lda op_result
        sta reg_cs
        lda op_result+1
        sta reg_cs+1

        jsr pop_word
        lda op_result
        sta op_source
        lda op_result+1
        sta op_source+1
        jsr word_to_flags

        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

; ============================================================================
; $0E — JMP / CALL near (E8/E9/EB)
; ============================================================================
op_jmp_call:
        lda raw_opcode
        cmp #$E8
        beq _jc_call_near
        cmp #$E9
        beq _jc_jmp_near16
        cmp #$EB
        beq _jc_jmp_short
        cmp #$EA
        beq _jc_jmp_far
        jmp opcode_done         ; Unknown

_jc_call_near:
        ; CALL rel16: push IP, then jump
        jsr fetch_word
        sta i_data0
        lda scratch_a
        sta i_data0+1
        ; Push current IP (after fetch = return address)
        lda reg_ip
        sta op_result
        lda reg_ip+1
        sta op_result+1
        jsr push_word
        ; IP += signed displacement
        clc
        lda reg_ip
        adc i_data0
        sta reg_ip
        lda reg_ip+1
        adc i_data0+1
        sta reg_ip+1
        jsr update_opcode_ptr
        jmp opcode_done

_jc_jmp_near16:
        ; JMP rel16
        jsr fetch_word
        sta i_data0
        lda scratch_a
        sta i_data0+1
        clc
        lda reg_ip
        adc i_data0
        sta reg_ip
        lda reg_ip+1
        adc i_data0+1
        sta reg_ip+1
        jsr update_opcode_ptr
        jmp opcode_done

_jc_jmp_short:
        ; JMP rel8
        jsr fetch_byte
        sta i_data0
        ldx #0
        cmp #$80
        bcc +
        ldx #$FF
+       stx i_data0+1
        clc
        lda reg_ip
        adc i_data0
        sta reg_ip
        lda reg_ip+1
        adc i_data0+1
        sta reg_ip+1
        jsr update_opcode_ptr
        jmp opcode_done

_jc_jmp_far:
        ; JMP seg:ofs (EA)
        jsr fetch_word          ; Offset
        sta i_data0
        lda scratch_a
        sta i_data0+1
        jsr fetch_word          ; Segment
        sta reg_cs
        lda scratch_a
        sta reg_cs+1
        lda i_data0
        sta reg_ip
        lda i_data0+1
        sta reg_ip+1
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

; ============================================================================
; $20 — CALL far (9A)
; ============================================================================
op_call_far:
        ; Fetch offset and segment
        jsr fetch_word
        sta i_data0
        lda scratch_a
        sta i_data0+1
        jsr fetch_word
        sta i_data1             ; New CS
        lda scratch_a
        sta i_data1+1

        ; Push CS
        lda reg_cs
        sta op_result
        lda reg_cs+1
        sta op_result+1
        jsr push_word

        ; Push IP (return address)
        lda reg_ip
        sta op_result
        lda reg_ip+1
        sta op_result+1
        jsr push_word

        ; Check if target matches INT 10h or INT 29h IVT vector
        jsr cf_check_int10
        bcs cf_do_int10
        jsr cf_check_int29
        bcs cf_do_int29
        bra cf_no_hook

cf_do_int10:
        jsr cf_pop_return
        jsr int10_handler
        jmp opcode_done

cf_do_int29:
        jsr cf_pop_return
        lda reg_al
        jsr con_write_char
        jmp opcode_done

cf_no_hook:
        ; Set new CS:IP
        lda i_data1
        sta reg_cs
        lda i_data1+1
        sta reg_cs+1
        lda i_data0
        sta reg_ip
        lda i_data0+1
        sta reg_ip+1
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

; --- CALL FAR hook helpers ---
cf_pop_return:
        jsr pop_word
        lda op_result
        sta reg_ip
        lda op_result+1
        sta reg_ip+1
        jsr pop_word
        lda op_result
        sta reg_cs
        lda op_result+1
        sta reg_cs+1
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        rts

cf_check_int10:
        lda #$40
        sta temp_ptr
        lda #$00
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        bra cf_check_common

cf_check_int29:
        lda #$A4
        sta temp_ptr
        lda #$00
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

cf_check_common:
        ldz #0
        lda [temp_ptr],z
        cmp i_data0
        bne cf_check_fail
        ldz #1
        lda [temp_ptr],z
        cmp i_data0+1
        bne cf_check_fail
        ldz #2
        lda [temp_ptr],z
        cmp i_data1
        bne cf_check_fail
        ldz #3
        lda [temp_ptr],z
        cmp i_data1+1
        bne cf_check_fail
        sec
        rts
cf_check_fail:
        clc
        rts

; ============================================================================
; $21 — PUSHF (9C)
; ============================================================================
op_pushf:
        jsr flags_to_word
        jsr push_word
        jmp opcode_done

; ============================================================================
; $22 — POPF (9D)
; ============================================================================
op_popf:
        jsr pop_word
        lda op_result
        sta op_source
        lda op_result+1
        sta op_source+1
        jsr word_to_flags
        jmp opcode_done

; ============================================================================
; $23 — SAHF (9E)
; ============================================================================
op_sahf:
        lda reg_ah
        and #$01
        sta flag_cf
        lda reg_ah
        and #$04
        beq +
        lda #1
+       sta flag_pf
        lda reg_ah
        and #$10
        beq +
        lda #1
+       sta flag_af
        lda reg_ah
        and #$40
        beq +
        lda #1
+       sta flag_zf
        lda reg_ah
        and #$80
        beq +
        lda #1
+       sta flag_sf
        jmp opcode_done

; ============================================================================
; $24 — LAHF (9F)
; ============================================================================
op_lahf:
        jsr flags_to_word       ; Low byte in op_result
        lda op_result
        sta reg_ah
        jmp opcode_done

; ============================================================================
; $1E — CBW (98)
; ============================================================================
op_cbw:
        lda reg_al
        and #$80
        beq +
        lda #$FF
        sta reg_ah
        jmp opcode_done
+       lda #0
        sta reg_ah
        jmp opcode_done

; ============================================================================
; $1F — CWD (99)
; ============================================================================
op_cwd:
        lda reg_ah
        and #$80
        beq +
        lda #$FF
        sta reg_dx
        sta reg_dx+1
        jmp opcode_done
+       lda #0
        sta reg_dx
        sta reg_dx+1
        jmp opcode_done

; ============================================================================
; $2E — CLC/STC/CLI/STI/CLD/STD (F8–FD)
; ============================================================================
op_clc_stc_etc:
        lda raw_opcode
        cmp #$F8
        beq _cse_clc
        cmp #$F9
        beq _cse_stc
        cmp #$FA
        beq _cse_cli
        cmp #$FB
        beq _cse_sti
        cmp #$FC
        beq _cse_cld
        cmp #$FD
        beq _cse_std
        jmp opcode_done
_cse_clc:
        lda #0
        sta flag_cf
        jmp opcode_done
_cse_stc:
        lda #1
        sta flag_cf
        jmp opcode_done
_cse_cli:
        lda #0
        sta flag_if
        jmp opcode_done
_cse_sti:
        lda #1
        sta flag_if
        jmp opcode_done
_cse_cld:
        lda #0
        sta flag_df
        jmp opcode_done
_cse_std:
        lda #1
        sta flag_df
        jmp opcode_done

; ============================================================================
; $2D — CMC (F5)
; ============================================================================
op_cmc:
        lda flag_cf
        eor #1
        sta flag_cf
        jmp opcode_done

; ============================================================================
; $31 — NOP / Unimplemented
; ============================================================================
; ============================================================================
; op_pusha — PUSHA (opcode $60): Push all general registers
; ============================================================================
; Push order: AX, CX, DX, BX, original SP, BP, SI, DI
op_pusha:
        ; Save original SP in dedicated location (push_word uses temp32!)
        lda reg_sp86
        sta pusha_saved_sp
        lda reg_sp86+1
        sta pusha_saved_sp+1

        ; Push AX
        lda reg_ax
        sta op_result
        lda reg_ax+1
        sta op_result+1
        jsr push_word
        ; Push CX
        lda reg_cx
        sta op_result
        lda reg_cx+1
        sta op_result+1
        jsr push_word
        ; Push DX
        lda reg_dx
        sta op_result
        lda reg_dx+1
        sta op_result+1
        jsr push_word
        ; Push BX
        lda reg_bx
        sta op_result
        lda reg_bx+1
        sta op_result+1
        jsr push_word
        ; Push original SP (saved before pushes)
        lda pusha_saved_sp
        sta op_result
        lda pusha_saved_sp+1
        sta op_result+1
        jsr push_word
        ; Push BP
        lda reg_bp86
        sta op_result
        lda reg_bp86+1
        sta op_result+1
        jsr push_word
        ; Push SI
        lda reg_si
        sta op_result
        lda reg_si+1
        sta op_result+1
        jsr push_word
        ; Push DI
        lda reg_di
        sta op_result
        lda reg_di+1
        sta op_result+1
        jsr push_word
        jmp opcode_done

; ============================================================================
; op_popa — POPA (opcode $61): Pop all general registers
; ============================================================================
; Pop order: DI, SI, BP, (skip SP), BX, DX, CX, AX
op_popa:
        ; Pop DI
        jsr pop_word
        lda op_result
        sta reg_di
        lda op_result+1
        sta reg_di+1
        ; Pop SI
        jsr pop_word
        lda op_result
        sta reg_si
        lda op_result+1
        sta reg_si+1
        ; Pop BP
        jsr pop_word
        lda op_result
        sta reg_bp86
        lda op_result+1
        sta reg_bp86+1
        ; Skip SP (pop but discard)
        jsr pop_word
        ; Pop BX
        jsr pop_word
        lda op_result
        sta reg_bx
        lda op_result+1
        sta reg_bx+1
        ; Pop DX
        jsr pop_word
        lda op_result
        sta reg_dx
        lda op_result+1
        sta reg_dx+1
        ; Pop CX
        jsr pop_word
        lda op_result
        sta reg_cx
        lda op_result+1
        sta reg_cx+1
        ; Pop AX
        jsr pop_word
        lda op_result
        sta reg_ax
        lda op_result+1
        sta reg_ax+1
        jmp opcode_done

; ============================================================================
; op_push_imm16 — PUSH imm16 (opcode $68)
; ============================================================================
op_push_imm16:
        jsr fetch_word          ; A = low, scratch_a = high
        sta op_result
        lda scratch_a
        sta op_result+1
        jsr push_word
        jmp opcode_done

; ============================================================================
; op_push_imm8 — PUSH imm8 sign-extended (opcode $6A)
; ============================================================================
op_push_imm8:
        jsr fetch_byte
        sta op_result
        ; Sign-extend
        lda #$00
        ldx op_result
        cpx #$80
        bcc +
        lda #$FF
+       sta op_result+1
        jsr push_word
        jmp opcode_done

; ============================================================================
; $39 — HLT (F4)
; ============================================================================
; On real 8086, HLT stops CPU until interrupt arrives.
; We simulate by delivering INT 8 (timer tick) if IF=1.
; This unblocks FreeDOS idle loops that do STI; HLT.
;
op_hlt:
        ; On real 8086, HLT waits for an interrupt.
        ; We can't deliver INT 8 via do_sw_interrupt (corrupts stack on attic segments).
        ; Instead: just bump the BDA timer counter and return.
        ; FreeDOS idle loop checks the timer counter, not the interrupt itself.
        lda #$6C
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda [temp_ptr],z
        clc
        adc #1
        sta [temp_ptr],z
        bcc +
        ldz #1
        lda [temp_ptr],z
        adc #0
        sta [temp_ptr],z
+
        jmp opcode_done

op_nop_unimpl:
        inc unimpl_count
        lda raw_opcode
        sta unimpl_last
        ; Some unimplemented opcodes have operands we must skip
        ; to keep the instruction stream aligned
        cmp #$C8                ; ENTER imm16, imm8 (4 bytes total)
        beq _nop_skip3
        cmp #$C9                ; LEAVE (1 byte, no operands)
        beq _nop_done
        cmp #$0F                ; 0F prefix (2-byte opcode, already consumed by emu_special)
        beq _nop_done
        ; D8-DF = FPU ESC — these have ModR/M (already decoded)
        cmp #$D8
        bcc _nop_done
        cmp #$E0
        bcc _nop_done           ; FPU: modrm already consumed by decode
        ; 60-6F range (PUSHA/POPA/BOUND/etc) — 1 byte, no extra
        jmp opcode_done
_nop_skip3:
        ; Skip 3 operand bytes (ENTER: imm16 + imm8)
        jsr fetch_byte
        jsr fetch_byte
        jsr fetch_byte
_nop_done:
        jmp opcode_done

; ============================================================================
; Remaining opcode handlers
; ============================================================================

; ============================================================================
; $07 — ALU acc, imm (04/05/0C/0D/14/15/1C/1D/24/25/2C/2D/34/35/3C/3D)
; ============================================================================
op_alu_imm_acc:
        ; Accumulator is dest, immediate is source
        ; ALU sub-op = extra_field (0–7)
        lda i_w
        beq _aia_byte
        ; Word: AX op imm16
        lda reg_ax
        sta op_dest
        lda reg_ax+1
        sta op_dest+1
        jsr fetch_word
        sta op_source
        lda scratch_a
        sta op_source+1
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        lda extra_field
        cmp #7                  ; CMP doesn't store
        beq _aia_done
        lda op_result
        sta reg_ax
        lda op_result+1
        sta reg_ax+1
_aia_done:
        jmp opcode_done
_aia_byte:
        ; Byte: AL op imm8
        lda reg_al
        sta op_dest
        lda #0
        sta op_dest+1
        jsr fetch_byte
        sta op_source
        lda #0
        sta op_source+1
        lda extra_field
        jsr alu_dispatch
        jsr compute_of_arith
        lda extra_field
        cmp #7
        beq _aia_done
        lda op_result
        sta reg_al
        jmp opcode_done

; ============================================================================
; $08 — ALU r/m, imm (80–83)
; ============================================================================
op_alu_imm_rm:
        ; Sub-operation comes from ModR/M reg field (i_reg), not extra_field
        ; 80: byte r/m, imm8
        ; 81: word r/m, imm16
        ; 82: byte r/m, imm8 (same as 80)
        ; 83: word r/m, sign-extended imm8
        lda i_reg
        sta extra_field         ; Set extra_field for compute_cf / compute_of_arith
        lda i_w
        beq _airm_byte

        ; Word mode: read r/m word as dest
        jsr read_rm16
        lda op_source
        sta op_dest
        lda op_source+1
        sta op_dest+1

        ; Fetch immediate
        lda raw_opcode
        cmp #$83
        beq _airm_sx8           ; Sign-extended byte
        ; 81: full 16-bit immediate
        jsr fetch_word
        sta op_source
        lda scratch_a
        sta op_source+1
        bra _airm_w_go

_airm_sx8:
        ; Sign-extend byte to word
        jsr fetch_byte
        sta op_source
        ldx #0
        cmp #$80
        bcc +
        ldx #$FF
+       stx op_source+1

_airm_w_go:
        lda i_reg              ; ALU sub-op from ModR/M reg field
        jsr alu_dispatch
        jsr compute_of_arith
        lda i_reg
        cmp #7                 ; CMP
        beq _airm_done
        jsr write_rm16
_airm_done:
        jmp opcode_done

_airm_byte:
        ; Byte mode
        jsr read_rm8
        sta op_dest
        lda #0
        sta op_dest+1
        jsr fetch_byte
        sta op_source
        lda #0
        sta op_source+1
        lda i_reg
        jsr alu_dispatch
        jsr compute_of_arith
        lda i_reg
        cmp #7
        beq _airm_done
        lda op_result
        jsr write_rm8
        jmp opcode_done

; ============================================================================
; $0A — MOV sreg (8C/8E)
; ============================================================================
op_mov_sreg:
        ; 8C: MOV r/m, sreg (i_d=0) — read segment reg, write to r/m
        ; 8E: MOV sreg, r/m (i_d=1) — read r/m, write to segment reg
        ; Segment reg = i_reg & 3: 0=ES, 1=CS, 2=SS, 3=DS
        lda i_reg
        and #$03
        asl                     ; ×2
        clc
        adc #SEG_ES_OFS         ; Offset from regs base
        tax                     ; X = register offset

        lda i_d
        bne _msreg_to_sreg

        ; 8C: r/m ← sreg
        lda regs,x
        sta op_result
        lda regs+1,x
        sta op_result+1
        jsr write_rm16
        jmp opcode_done

_msreg_to_sreg:
        ; 8E: sreg ← r/m
        phx                     ; Save segment register offset
        jsr read_rm16
        plx                     ; Restore segment register offset
        lda op_source
        sta regs,x
        lda op_source+1
        sta regs+1,x

        ; Mark appropriate segment dirty
        cpx #SEG_CS_OFS
        bne +
        lda #1
        sta cs_dirty
        jmp opcode_done
+       cpx #SEG_SS_OFS
        bne +
        lda #1
        sta ss_dirty
        jmp opcode_done
+       cpx #SEG_DS_OFS
        bne +
        lda #1
        sta ds_dirty
+       jmp opcode_done

; ============================================================================
; $0B — MOV acc, mem (A0–A3)
; ============================================================================
op_mov_acc_mem:
        ; A0: AL ← [mem8]   A1: AX ← [mem16]
        ; A2: [mem8] ← AL   A3: [mem16] ← AX
        ; Address is direct 16-bit offset (following the opcode)
        jsr fetch_word
        sta temp32
        lda scratch_a
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3

        lda raw_opcode
        cmp #$A2
        bcs _mam_store

        ; Load: acc ← memory
        ldx #SEG_DS_OFS
        lda i_w
        beq _mam_load_byte
        jsr mem_read16
        lda op_source
        sta reg_ax
        lda op_source+1
        sta reg_ax+1
        jmp opcode_done
_mam_load_byte:
        jsr mem_read8
        sta reg_al
        jmp opcode_done

_mam_store:
        ; Store: memory ← acc
        ldx #SEG_DS_OFS
        lda i_w
        beq _mam_store_byte
        lda reg_ax
        sta op_result
        lda reg_ax+1
        sta op_result+1
        jsr mem_write16
        jmp opcode_done
_mam_store_byte:
        lda reg_al
        sta scratch_d
        jsr mem_write8
        jmp opcode_done

; ============================================================================
; $0C — Shift/Rotate (C0/C1/D0–D3)
; ============================================================================
op_shift_rot:
        ; Sub-operation from i_reg: 0=ROL 1=ROR 2=RCL 3=RCR 4=SHL 5=SHR 6=- 7=SAR
        ; Count: D0/D1=1, D2/D3=CL, C0/C1=imm8
        lda raw_opcode
        cmp #$C0
        beq _sr_imm_count
        cmp #$C1
        beq _sr_imm_count
        cmp #$D2
        beq _sr_cl_count
        cmp #$D3
        beq _sr_cl_count
        ; D0/D1: count = 1
        lda #1
        sta scratch_c
        bra _sr_go
_sr_imm_count:
        jsr fetch_byte
        and #$1F                ; Mask to 5 bits (8086 masks to 5)
        sta scratch_c
        bra _sr_go
_sr_cl_count:
        lda reg_cl
        and #$1F
        sta scratch_c

_sr_go:
        lda scratch_c
        beq _sr_done_jmp       ; Count=0: no operation

        ; Read operand
        lda i_w
        beq _sr_byte
        jsr read_rm16
        lda op_source
        sta op_dest
        lda op_source+1
        sta op_dest+1
        bra _sr_loop
_sr_byte:
        jsr read_rm8
        sta op_dest
        lda #0
        sta op_dest+1

_sr_loop:
        ; Dispatch to shift sub-op
        lda i_reg
        asl
        tax
        jmp (_sr_sub_tbl,x)

_sr_sub_tbl:
        .word _sr_rol           ; 0
        .word _sr_ror           ; 1
        .word _sr_rcl           ; 2
        .word _sr_rcr           ; 3
        .word _sr_shl           ; 4
        .word _sr_shr           ; 5
        .word _sr_shl           ; 6 (undefined, treat as SHL)
        .word _sr_sar           ; 7

_sr_rol:
        lda i_w
        beq _sr_rol_b
        ; Word ROL
        asl op_dest
        rol op_dest+1
        bcc +
        inc op_dest             ; Wrap bit 15 to bit 0
+       lda op_dest
        and #$01
        sta flag_cf
        bra _sr_next
_sr_rol_b:
        asl op_dest
        bcc +
        inc op_dest
+       lda op_dest
        and #$01
        sta flag_cf
        bra _sr_next

_sr_ror:
        lda i_w
        beq _sr_ror_b
        ; Word ROR
        lda op_dest
        and #$01
        sta flag_cf
        lsr op_dest+1
        ror op_dest
        lda flag_cf
        beq +
        lda #$80
        ora op_dest+1
        sta op_dest+1
+       bra _sr_next
_sr_ror_b:
        lda op_dest
        and #$01
        sta flag_cf
        lsr op_dest
        lda flag_cf
        beq +
        lda #$80
        ora op_dest
        sta op_dest
+       bra _sr_next

_sr_rcl:
        ; Rotate through carry left
        lda flag_cf
        sta scratch_d           ; Save old CF
        lda i_w
        beq _sr_rcl_b
        asl op_dest
        rol op_dest+1
        bcc _sr_rcl_w_nc
        lda #1
        sta flag_cf
        bra _sr_rcl_w_oldcf
_sr_rcl_w_nc:
        lda #0
        sta flag_cf
_sr_rcl_w_oldcf:
        lda scratch_d
        beq +
        inc op_dest             ; Old CF goes to bit 0
+       bra _sr_next
_sr_rcl_b:
        asl op_dest
        bcc _sr_rcl_b_nc
        lda #1
        sta flag_cf
        bra _sr_rcl_b_oldcf
_sr_rcl_b_nc:
        lda #0
        sta flag_cf
_sr_rcl_b_oldcf:
        lda scratch_d
        beq +
        inc op_dest
+       bra _sr_next

_sr_rcr:
        lda flag_cf
        sta scratch_d
        lda i_w
        beq _sr_rcr_b
        lda op_dest
        and #$01
        pha
        lsr op_dest+1
        ror op_dest
        lda scratch_d
        beq +
        lda #$80
        ora op_dest+1
        sta op_dest+1
+       pla
        sta flag_cf
        bra _sr_next
_sr_rcr_b:
        lda op_dest
        and #$01
        pha
        lsr op_dest
        lda scratch_d
        beq +
        lda #$80
        ora op_dest
        sta op_dest
+       pla
        sta flag_cf
        bra _sr_next

_sr_shl:
        lda i_w
        beq _sr_shl_b
        asl op_dest
        rol op_dest+1
        lda #0
        rol                     ; Capture carry into A bit 0
        sta flag_cf
        bra _sr_next
_sr_shl_b:
        asl op_dest
        lda #0
        rol
        sta flag_cf
        bra _sr_next

_sr_shr:
        lda i_w
        beq _sr_shr_b
        lda op_dest
        and #$01
        sta flag_cf
        lsr op_dest+1
        ror op_dest
        bra _sr_next
_sr_shr_b:
        lda op_dest
        and #$01
        sta flag_cf
        lsr op_dest
        bra _sr_next

_sr_sar:
        lda i_w
        beq _sr_sar_b
        lda op_dest
        and #$01
        sta flag_cf
        lda op_dest+1
        pha                     ; Save sign bit
        lsr op_dest+1
        ror op_dest
        pla
        and #$80
        ora op_dest+1           ; Preserve sign
        sta op_dest+1
        bra _sr_next
_sr_sar_b:
        lda op_dest
        and #$01
        sta flag_cf
        lda op_dest
        and #$80
        sta scratch_d           ; Save sign
        lsr op_dest
        lda scratch_d
        ora op_dest
        sta op_dest
        ; Fall through

_sr_next:
        dec scratch_c
        beq _sr_write
        jmp _sr_loop
_sr_done_jmp:
        jmp opcode_done

_sr_write:
        ; Store result and set flags
        lda op_dest
        sta op_result
        lda op_dest+1
        sta op_result+1
        lda i_w
        beq _sr_write_b
        jsr write_rm16
        bra _sr_flags
_sr_write_b:
        lda op_result
        jsr write_rm8
_sr_flags:
        jsr set_flags_logic     ; ZF, SF, PF
        ; OF: set if sign changed on count=1 shifts (simplified: always compute)
        jmp opcode_done

; ============================================================================
; $0D — LOOP/LOOPZ/LOOPNZ/JCXZ (E0–E3)
; ============================================================================
op_loop:
        ; Fetch signed displacement
        jsr fetch_byte
        sta i_data0
        ldx #0
        cmp #$80
        bcc +
        ldx #$FF
+       stx i_data0+1

        lda raw_opcode
        cmp #$E3
        beq _loop_jcxz

        ; LOOP variants: decrement CX first
        sec
        lda reg_cx
        sbc #1
        sta reg_cx
        lda reg_cx+1
        sbc #0
        sta reg_cx+1

        ; Check CX != 0
        lda reg_cx
        ora reg_cx+1
        beq _loop_no_jump       ; CX=0: don't loop

        lda raw_opcode
        cmp #$E0
        beq _loop_nz            ; LOOPNZ
        cmp #$E1
        beq _loop_z             ; LOOPZ
        bra _loop_take          ; E2 = LOOP (always if CX!=0)

_loop_nz:
        lda flag_zf
        bne _loop_no_jump       ; ZF=1 → don't loop
        bra _loop_take
_loop_z:
        lda flag_zf
        beq _loop_no_jump       ; ZF=0 → don't loop
        bra _loop_take

_loop_jcxz:
        ; Jump if CX=0
        lda reg_cx
        ora reg_cx+1
        bne _loop_no_jump

_loop_take:
        clc
        lda reg_ip
        adc i_data0
        sta reg_ip
        lda reg_ip+1
        adc i_data0+1
        sta reg_ip+1
        jsr update_opcode_ptr
_loop_no_jump:
        jmp opcode_done

; ============================================================================
; $0F — TEST r/m, reg (84/85)
; ============================================================================
op_test_rm:
        ; AND operands but don't store result (only set flags)
        jsr load_reg_operand   ; reg value in op_dest
        lda i_w
        beq _trm_byte
        jsr read_rm16
        lda op_source
        and op_dest
        sta op_result
        lda op_source+1
        and op_dest+1
        sta op_result+1
        bra _trm_flags
_trm_byte:
        jsr read_rm8
        and op_dest
        sta op_result
        lda #0
        sta op_result+1
_trm_flags:
        lda #0
        sta flag_cf
        sta flag_of
        jsr set_flags_logic
        jmp opcode_done

; ============================================================================
; $10 — XCHG AX, r16 (90–97)
; ============================================================================
op_xchg_ax:
        lda raw_opcode
        and #$07
        beq _xa_nop             ; 90 = XCHG AX,AX = NOP
        asl
        tax
        ; Swap AX with regs[x]
        lda reg_ax
        pha
        lda reg_ax+1
        pha
        lda regs,x
        sta reg_ax
        lda regs+1,x
        sta reg_ax+1
        pla
        sta regs+1,x
        pla
        sta regs,x
_xa_nop:
        jmp opcode_done

; ============================================================================
; $11 — MOVS/STOS/LODS (A4/A5/AA/AB/AC/AD)
; ============================================================================
op_movs_stos:
        lda raw_opcode
        cmp #$AA
        bcs _ms_stos_lods
        ; A4/A5: MOVS — move string
        ; Read from DS:SI, write to ES:DI
        lda reg_si
        sta temp32
        lda reg_si+1
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read8           ; A = byte (for now always byte path)
        sta scratch_d
        lda i_w
        beq _movs_byte
        ; Word: read second byte
        inc temp32
        bne +
        inc temp32+1
+       ldx #SEG_DS_OFS
        lda reg_si
        clc
        adc #1
        sta temp32
        lda reg_si+1
        adc #0
        sta temp32+1
        jsr mem_read8
        sta scratch_a           ; High byte

_movs_byte:
        ; Write to ES:DI (must force ES regardless of segment override)
        lda reg_di
        sta temp32
        lda reg_di+1
        sta temp32+1
        lda scratch_d
        sta scratch_d           ; Value to write (byte mode)
        ldx #SEG_ES_OFS
        lda seg_override_en
        pha
        lda #0
        sta seg_override_en     ; Force ES for destination
        lda i_w
        beq _movs_wr_byte
        ; Word mode: save high byte on stack before write (seg_ofs_to_linear trashes scratch_a)
        lda scratch_a
        pha
        lda scratch_d           ; restore low byte to scratch_d (just in case)
        sta scratch_d
        ldx #SEG_ES_OFS
        jsr mem_write8
        ; Write high byte
        lda reg_di
        clc
        adc #1
        sta temp32
        lda reg_di+1
        adc #0
        sta temp32+1
        pla                     ; Recover high byte from stack
        sta scratch_d
        ldx #SEG_ES_OFS
        jsr mem_write8
        pla
        sta seg_override_en     ; Restore override for REP
        bra _movs_upd

_movs_wr_byte:
        jsr mem_write8

        pla
        sta seg_override_en     ; Restore override for REP

_movs_upd:
        ; Update SI and DI based on DF
        lda i_w
        beq _movs_upd1
        lda #2
        bra _movs_upd_go
_movs_upd1:
        lda #1
_movs_upd_go:
        sta scratch_b           ; Step size (1 or 2)
        lda flag_df
        bne _movs_dec
        ; DF=0: increment
        clc
        lda reg_si
        adc scratch_b
        sta reg_si
        lda reg_si+1
        adc #0
        sta reg_si+1
        clc
        lda reg_di
        adc scratch_b
        sta reg_di
        lda reg_di+1
        adc #0
        sta reg_di+1
        jmp opcode_done
_movs_dec:
        sec
        lda reg_si
        sbc scratch_b
        sta reg_si
        lda reg_si+1
        sbc #0
        sta reg_si+1
        sec
        lda reg_di
        sbc scratch_b
        sta reg_di
        lda reg_di+1
        sbc #0
        sta reg_di+1
        jmp opcode_done

_ms_stos_lods:
        lda raw_opcode
        cmp #$AC
        bcs _ms_lods
        ; AA/AB: STOS — store AL/AX to ES:DI (must force ES)
        lda reg_di
        sta temp32
        lda reg_di+1
        sta temp32+1
        lda reg_al
        sta scratch_d
        ldx #SEG_ES_OFS
        lda seg_override_en
        pha
        lda #0
        sta seg_override_en     ; Force ES for destination
        jsr mem_write8
        lda i_w
        beq _stos_restore
        ; Word: store AH to next byte
        lda reg_di
        clc
        adc #1
        sta temp32
        lda reg_di+1
        adc #0
        sta temp32+1
        lda reg_ah
        sta scratch_d
        ldx #SEG_ES_OFS
        jsr mem_write8
_stos_restore:
        pla
        sta seg_override_en     ; Restore override for REP
_stos_upd:
        ; Update DI
        lda #1
        ldx i_w
        beq +
        lda #2
+       sta scratch_b
        lda flag_df
        bne _stos_dec
        clc
        lda reg_di
        adc scratch_b
        sta reg_di
        lda reg_di+1
        adc #0
        sta reg_di+1
        jmp opcode_done
_stos_dec:
        sec
        lda reg_di
        sbc scratch_b
        sta reg_di
        lda reg_di+1
        sbc #0
        sta reg_di+1
        jmp opcode_done

_ms_lods:
        ; AC/AD: LODS — load DS:SI to AL/AX
        lda reg_si
        sta temp32
        lda reg_si+1
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read8
        sta reg_al
        lda i_w
        beq _lods_upd
        ; Word
        lda reg_si
        clc
        adc #1
        sta temp32
        lda reg_si+1
        adc #0
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read8
        sta reg_ah
_lods_upd:
        lda #1
        ldx i_w
        beq +
        lda #2
+       sta scratch_b
        lda flag_df
        bne _lods_dec
        clc
        lda reg_si
        adc scratch_b
        sta reg_si
        lda reg_si+1
        adc #0
        sta reg_si+1
        jmp opcode_done
_lods_dec:
        sec
        lda reg_si
        sbc scratch_b
        sta reg_si
        lda reg_si+1
        sbc #0
        sta reg_si+1
        jmp opcode_done

; ============================================================================
; $12 — CMPS/SCAS (A6/A7/AE/AF)
; ============================================================================
op_cmps_scas:
        lda raw_opcode
        cmp #$AE
        bcs _cs_scas

        ; A6/A7: CMPS — compare DS:SI with ES:DI
        lda reg_si
        sta temp32
        lda reg_si+1
        sta temp32+1
        ldx #SEG_DS_OFS
        lda i_w
        bne _cmps_word_src
        jsr mem_read8
        sta op_dest
        lda #0
        sta op_dest+1
        bra _cmps_read_dst
_cmps_word_src:
        jsr mem_read16
        lda op_source
        sta op_dest
        lda op_source+1
        sta op_dest+1
_cmps_read_dst:
        ; Read ES:DI (must force ES regardless of segment override)
        lda reg_di
        sta temp32
        lda reg_di+1
        sta temp32+1
        ldx #SEG_ES_OFS
        lda seg_override_en
        pha
        lda #0
        sta seg_override_en     ; Force ES
        lda i_w
        bne _cmps_word_dst
        jsr mem_read8
        sta op_source
        lda #0
        sta op_source+1
        bra _cmps_dst_done
_cmps_word_dst:
        jsr mem_read16          ; Result in op_source+0/+1
_cmps_dst_done:
        pla
        sta seg_override_en     ; Restore override for REP
_cmps_do:
        ; CMP dest - source
        lda #5                  ; SUB
        sta extra_field         ; Tell compute_cf / compute_of_arith this is SUB
        jsr alu_dispatch
        jsr compute_of_arith

        ; Update SI, DI
        lda #1
        ldx i_w
        beq +
        lda #2
+       sta scratch_b
        lda flag_df
        bne _cmps_dec
        clc
        lda reg_si
        adc scratch_b
        sta reg_si
        lda reg_si+1
        adc #0
        sta reg_si+1
        clc
        lda reg_di
        adc scratch_b
        sta reg_di
        lda reg_di+1
        adc #0
        sta reg_di+1
        jmp opcode_done
_cmps_dec:
        sec
        lda reg_si
        sbc scratch_b
        sta reg_si
        lda reg_si+1
        sbc #0
        sta reg_si+1
        sec
        lda reg_di
        sbc scratch_b
        sta reg_di
        lda reg_di+1
        sbc #0
        sta reg_di+1
        jmp opcode_done

_cs_scas:
        ; AE/AF: SCAS — compare AL/AX with ES:DI
        lda reg_al
        sta op_dest
        lda #0
        ldx i_w
        beq +
        lda reg_ah
+       sta op_dest+1

        lda reg_di
        sta temp32
        lda reg_di+1
        sta temp32+1
        ldx #SEG_ES_OFS
        lda seg_override_en
        pha
        lda #0
        sta seg_override_en     ; Force ES
        lda i_w
        bne _scas_word
        jsr mem_read8
        sta op_source
        lda #0
        sta op_source+1
        bra _scas_src_done
_scas_word:
        jsr mem_read16          ; Result in op_source+0/+1
_scas_src_done:
        pla
        sta seg_override_en     ; Restore override for REP

        lda #5                  ; SUB (CMP)
        sta extra_field         ; Tell compute_cf / compute_of_arith this is SUB
        jsr alu_dispatch
        jsr compute_of_arith

        ; Update DI
        lda #1
        ldx i_w
        beq +
        lda #2
+       sta scratch_b
        lda flag_df
        bne _scas_dec
        clc
        lda reg_di
        adc scratch_b
        sta reg_di
        lda reg_di+1
        adc #0
        sta reg_di+1
        jmp opcode_done
_scas_dec:
        sec
        lda reg_di
        sbc scratch_b
        sta reg_di
        lda reg_di+1
        sbc #0
        sta reg_di+1
        jmp opcode_done

; ============================================================================
; $14 — MOV r/m, imm (C6/C7)
; ============================================================================
op_mov_rm_imm:
        lda i_w
        beq _mri_b
        ; Word
        jsr fetch_word
        sta op_result
        lda scratch_a
        sta op_result+1
        jsr write_rm16
        jmp opcode_done
_mri_b:
        jsr fetch_byte
        jsr write_rm8
        jmp opcode_done

; ============================================================================
; $15 — IN (E4/E5/EC/ED)
; ============================================================================
op_in:
        ; E4: IN AL, imm8    E5: IN AX, imm8
        ; EC: IN AL, DX      ED: IN AX, DX
        lda raw_opcode
        cmp #$EC
        bcs _in_dx
        ; Immediate port
        jsr fetch_byte
        sta temp32
        lda #0
        sta temp32+1
        bra _in_read
_in_dx:
        lda reg_dx
        sta temp32
        lda reg_dx+1
        sta temp32+1
_in_read:
        jsr io_read_port
        sta reg_al
        lda i_w
        beq _in_done
        ; Word: read high byte from port+1
        inc temp32
        bne +
        inc temp32+1
+       jsr io_read_port
        sta reg_ah
_in_done:
        jmp opcode_done

; ============================================================================
; $16 — OUT (E6/E7/EE/EF)
; ============================================================================
op_out:
        lda raw_opcode
        cmp #$EE
        bcs _out_dx
        jsr fetch_byte
        sta temp32
        lda #0
        sta temp32+1
        bra _out_write
_out_dx:
        lda reg_dx
        sta temp32
        lda reg_dx+1
        sta temp32+1
_out_write:
        lda reg_al
        jsr io_write_port
        lda i_w
        beq _out_done
        ; Word: write high byte to port+1
        inc temp32
        bne +
        inc temp32+1
+       lda reg_ah
        jsr io_write_port
_out_done:
        jmp opcode_done

; ============================================================================
; $17 — REP prefix execution (F2/F3)
; ============================================================================
op_rep:
        ; REP is handled as a prefix in the main loop.
        ; If we get here, it means REP was dispatched as an opcode.
        ; This shouldn't normally happen since prefixes are consumed in ml_next.
        ; But if it does, just NOP.
        jmp opcode_done

; ============================================================================
; $18 — XCHG r/m, reg (86/87)
; ============================================================================
op_xchg_rm:
        lda i_w
        beq _xr_byte
        ; Word
        jsr read_rm16           ; op_source = r/m value
        lda i_reg
        asl
        tax
        ; Save reg value
        lda regs,x
        pha
        lda regs+1,x
        pha
        ; reg ← r/m
        lda op_source
        sta regs,x
        lda op_source+1
        sta regs+1,x
        ; r/m ← old reg
        pla
        sta op_result+1
        pla
        sta op_result
        jsr write_rm16
        jmp opcode_done
_xr_byte:
        jsr read_rm8
        pha                     ; Save r/m value
        ; Get reg byte
        lda i_reg
        cmp #4
        bcs _xr_b_hi
        asl
        tax
        lda regs,x             ; Old reg value
        sta scratch_d
        pla
        sta regs,x             ; reg ← r/m
        lda scratch_d
        jsr write_rm8           ; r/m ← old reg
        jmp opcode_done
_xr_b_hi:
        sec
        sbc #4
        asl
        tax
        lda regs+1,x
        sta scratch_d
        pla
        sta regs+1,x
        lda scratch_d
        jsr write_rm8
        jmp opcode_done

; ============================================================================
; $19 — PUSH segment (06/0E/16/1E)
; ============================================================================
op_push_seg:
        ; extra_field = segment register offset from regs
        ldx extra_field
        lda regs,x
        sta op_result
        lda regs+1,x
        sta op_result+1
        jsr push_word
        jmp opcode_done

; ============================================================================
; $1A — POP segment (07/17/1F)
; ============================================================================
op_pop_seg:
        jsr pop_word
        ldx extra_field
        lda op_result
        sta regs,x
        lda op_result+1
        sta regs+1,x
        ; Mark dirty
        cpx #SEG_CS_OFS
        bne +
        lda #1
        sta cs_dirty
        jmp opcode_done
+       cpx #SEG_SS_OFS
        bne +
        lda #1
        sta ss_dirty
        jmp opcode_done
+       cpx #SEG_DS_OFS
        bne +
        lda #1
        sta ds_dirty
+       jmp opcode_done

; ============================================================================
; $1B — Segment override (26/2E/36/3E)
; ============================================================================
op_seg_override:
        ; This is handled in the main loop prefix section.
        ; If we reach here, just set override and continue.
        lda extra_field
        sta seg_override
        lda #1
        sta seg_override_en
        jmp opcode_done

; ============================================================================
; $1C — DAA/DAS (27/2F)
; ============================================================================
op_daa_das:
        lda raw_opcode
        cmp #$27
        beq _daa
        ; DAS
        lda reg_al
        sta op_dest
        lda flag_cf
        sta scratch_d           ; Save old CF
        lda #0
        sta flag_cf
        ; If low nibble > 9 or AF set
        lda reg_al
        and #$0F
        cmp #$0A
        bcs _das_adj_lo
        lda flag_af
        beq _das_check_hi
_das_adj_lo:
        sec
        lda reg_al
        sbc #$06
        sta reg_al
        lda #1
        sta flag_af
        ; CF = old_CF OR borrow
        bcs +
        lda #1
        sta flag_cf
+
_das_check_hi:
        ; Check old AL > $99 OR old CF
        lda op_dest
        cmp #$9A
        bcs _das_adj_hi
        lda scratch_d           ; Check OLD CF (not current)
        beq _das_done
_das_adj_hi:
        sec
        lda reg_al
        sbc #$60
        sta reg_al
        lda #1
        sta flag_cf
_das_done:
        lda reg_al
        sta op_result
        lda #0
        sta op_result+1
        jsr set_flags_logic
        jmp opcode_done

_daa:
        lda reg_al
        sta op_dest
        lda flag_cf
        sta scratch_d           ; Save old CF
        lda #0
        sta flag_cf
        lda reg_al
        and #$0F
        cmp #$0A
        bcs _daa_adj_lo
        lda flag_af
        beq _daa_check_hi
_daa_adj_lo:
        clc
        lda reg_al
        adc #$06
        sta reg_al
        lda #1
        sta flag_af
        ; CF = old_CF OR carry
        bcc +
        lda #1
        sta flag_cf
+
_daa_check_hi:
        ; Check old AL > $99 OR old CF
        lda op_dest
        cmp #$9A
        bcs _daa_adj_hi
        lda scratch_d           ; Check OLD CF (not current)
        beq _daa_done
_daa_adj_hi:
        clc
        lda reg_al
        adc #$60
        sta reg_al
        lda #1
        sta flag_cf
_daa_done:
        lda reg_al
        sta op_result
        lda #0
        sta op_result+1
        jsr set_flags_logic
        jmp opcode_done

; ============================================================================
; $1D — AAA/AAS (37/3F)
; ============================================================================
op_aaa_aas:
        lda raw_opcode
        cmp #$37
        beq _aaa
        ; AAS
        lda reg_al
        and #$0F
        cmp #$0A
        bcs _aas_adj
        lda flag_af
        bne _aas_adj
        ; No adjustment: clear AF and CF
        lda #0
        sta flag_af
        sta flag_cf
        bra _aas_done
_aas_adj:
        sec
        lda reg_al
        sbc #$06
        sta reg_al
        dec reg_ah
        lda #1
        sta flag_af
        sta flag_cf
_aas_done:
        lda reg_al
        and #$0F
        sta reg_al
        jmp opcode_done

_aaa:
        lda reg_al
        and #$0F
        cmp #$0A
        bcs _aaa_adj
        lda flag_af
        bne _aaa_adj
        ; No adjustment: clear AF and CF
        lda #0
        sta flag_af
        sta flag_cf
        bra _aaa_done
_aaa_adj:
        clc
        lda reg_al
        adc #$06
        sta reg_al
        inc reg_ah
        lda #1
        sta flag_af
        sta flag_cf
_aaa_done:
        lda reg_al
        and #$0F
        sta reg_al
        jmp opcode_done

; ============================================================================
; $25 — LES/LDS (C4/C5)
; ============================================================================
op_les_lds:
        ; Load far pointer: reg ← [r/m], segment ← [r/m+2]
        ; C4: LES (extra_field = ES offset)
        ; C5: LDS (extra_field = DS offset)

        ; Read offset from ea_offset using mem_read16 (cache-safe)
        lda ea_offset_lo
        sta temp32
        lda ea_offset_hi
        sta temp32+1
        ; Save segment override (mem_read16 uses seg_ofs_to_linear)
        lda seg_override_en
        pha
        lda seg_override
        pha
        ldx #SEG_DS_OFS
        jsr mem_read16          ; op_source = offset word

        ; Store offset in destination register
        lda i_reg
        asl
        tax
        lda op_source
        sta regs,x
        lda op_source+1
        sta regs+1,x

        ; Restore segment override for second read
        pla
        sta seg_override
        pla
        sta seg_override_en

        ; Read segment from ea_offset+2 (cache-safe)
        clc
        lda ea_offset_lo
        adc #2
        sta temp32
        lda ea_offset_hi
        adc #0
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read16          ; op_source = segment word

        ; Store segment
        ldx extra_field         ; ES or DS offset
        lda op_source
        sta regs,x
        lda op_source+1
        sta regs+1,x

        ; Mark segment dirty
        cpx #SEG_ES_OFS
        bne +
        jmp opcode_done         ; ES doesn't have a cached base
+       cpx #SEG_DS_OFS
        bne +
        lda #1
        sta ds_dirty
+       jmp opcode_done

; ============================================================================
; $26 — INT 3 (CC)
; ============================================================================
op_int3:
        lda #3
        jsr do_sw_interrupt
        jsr compute_cs_base
        jmp opcode_done

; ============================================================================
; $27 — INT imm (CD)
; ============================================================================
op_int_imm:
        jsr fetch_byte
        ; Count INT 0 (divide overflow)
        cmp #$00
        bne _ii_not0_count
        inc $8F14
_ii_not0_count:
        ; Check for emulator hooks
        cmp #$13
        beq _ii_int13
        cmp #$10
        beq _ii_int10
        cmp #$16
        beq _ii_int16
        cmp #$12
        beq _ii_int12
        cmp #$11
        beq _ii_int11
        cmp #$29
        beq _ii_int29
        cmp #$15
        beq _ii_int15
        cmp #$19
        beq _ii_int19
        cmp #$21
        beq _ii_int21
        ; Default: execute via IVT
        jsr do_sw_interrupt
        jsr compute_cs_base
        jmp opcode_done

_ii_int21:
        ; Intercept console output functions. All else goes to DOS.
        lda reg_ah
        cmp #$02
        beq _ii_int21_ah02
        cmp #$06
        beq _ii_int21_ah06
        cmp #$09
        beq _ii_int21_ah09
        ; All other INT 21h functions: let DOS handle via IVT
        lda #$21
        jsr do_sw_interrupt
        jsr compute_cs_base
        jmp opcode_done

_ii_int21_ah02:
        lda reg_dl
        jsr con_write_char
        jmp opcode_done

_ii_int21_ah06:
        lda reg_dl
        cmp #$FF
        beq _i21_06_input
        jsr con_write_char
        jmp opcode_done
_i21_06_input:
        lda #$21
        jsr do_sw_interrupt
        jsr compute_cs_base
        jmp opcode_done

_ii_int21_ah09:
        ; AH=09: Print $-terminated string at DS:DX
        jsr cache_flush_all
        lda reg_dx
        sta temp32
        lda reg_dx+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3
        sta seg_override_en
        ldx #SEG_DS_OFS
        jsr seg_ofs_to_linear
        lda temp32
        sta $8FD0
        lda temp32+1
        sta $8FD1
        lda temp32+2
        sta $8FD2
_i21_09_loop:
        lda $8FD0
        sta temp32
        lda $8FD1
        sta temp32+1
        lda $8FD2
        sta temp32+2
        lda #0
        sta temp32+3
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        cmp #'$'
        beq _i21_09_done
        jsr con_write_char
        inc $8FD0
        bne _i21_09_loop
        inc $8FD1
        bne _i21_09_loop
        inc $8FD2
        bra _i21_09_loop
_i21_09_done:
        jmp opcode_done


_ii_int13:
        ; INT 13h — disk services (intercepted)
        jsr int13_handler
        jmp opcode_done

_ii_int10:
        ; INT 10h — video services
        jsr int10_handler
        jmp opcode_done

_ii_int16:
        ; INT 16h — keyboard services
        jsr int16_handler
        jmp opcode_done

_ii_int29:
        ; INT 29h — Fast console output
        lda reg_al
        jsr con_write_char
        jmp opcode_done

_ii_int15:
        ; INT 15h — System services
        ; AH=88: Get extended memory size → return 0 (no extended memory)
        ; AH=C0: Get system config → return CF=1 (not supported)
        ; All others: return CF=1, AH=86 (unsupported)
        lda reg_ah
        cmp #$88
        bne _i15_not88
        lda #0
        sta reg_ax
        sta reg_ax+1            ; AX=0 (0KB extended memory)
        sta flag_cf             ; CF=0 success
        jmp opcode_done
_i15_not88:
        lda reg_ah
        cmp #$90
        beq _i15_device_wait    ; AH=90: Device busy (wait)
        cmp #$91
        beq _i15_device_wait    ; AH=91: Interrupt complete
        ; All others: return CF=1, AH=86 (unsupported)
        lda #$86
        sta reg_ah
        lda #1
        sta flag_cf             ; CF=1 error
        jmp opcode_done

_i15_device_wait:
        ; AH=90/91: Real BIOS returns CF=0 as a no-op
        ; Keyboard wait (INT 16h AH=00) calls INT 15h AH=90
        ; to allow multitasking hooks. Must succeed or callers hang.
        lda #0
        sta flag_cf             ; CF=0 success
        jmp opcode_done

_ii_int12:
        ; INT 12h — Get conventional memory size
        ; Returns AX = memory size in KB
        lda #RAM_KB_LO
        sta reg_al
        lda #RAM_KB_HI
        sta reg_ah
        lda #0
        sta flag_cf             ; CF=0 success
        jmp opcode_done

_ii_int11:
        ; INT 11h — Get equipment list
        ; Returns AX = equipment word
        ; Bit 0 = floppy present, bits 4-5 = video mode
        lda #VIDEO_EQUIP        ; From config in main.asm
        sta reg_al
        lda #$00
        sta reg_ah
        jmp opcode_done

_ii_int19:
        ; INT 19h — reboot. Print message and halt.
        lda #$0D
        jsr chrout_safe
        ldx #0
-       lda _reboot_msg,x
        beq +
        phx
        jsr chrout_safe         ; String is already PETSCII from .text
        plx
        inx
        bra -
+       jmp _ii_int19           ; Loop forever (reboot requested)
_reboot_msg:
        .text "INT 19H: REBOOT REQUESTED", $0D, 0

; ============================================================================
; $28 — INTO (CE)
; ============================================================================
op_into:
        lda flag_of
        beq +
        lda #4
        jsr do_sw_interrupt
        jsr compute_cs_base
+       jmp opcode_done

; ============================================================================
; $29 — AAM (D4)
; ============================================================================
op_aam:
        jsr fetch_byte          ; Divisor (usually 10)
        sta scratch_a
        beq _aam_div0           ; Division by zero
        ; AH = AL / divisor, AL = AL mod divisor
        lda reg_al
        ldx #0
-       cmp scratch_a
        bcc +
        sec
        sbc scratch_a
        inx
        bra -
+       sta reg_al              ; Remainder
        stx reg_ah              ; Quotient
        lda reg_al
        sta op_result
        lda #0
        sta op_result+1
        jsr set_flags_logic
        jmp opcode_done
_aam_div0:
        ; INT 0 on division by zero
        lda #0
        jsr do_sw_interrupt
        jsr compute_cs_base
        jmp opcode_done

; ============================================================================
; $2A — AAD (D5)
; ============================================================================
op_aad:
        jsr fetch_byte          ; Multiplier (usually 10)
        sta scratch_a
        ; AL = AH * multiplier + AL
        lda reg_ah
        ; Multiply AH × scratch_a using hardware multiplier
        sta $D770
        lda #0
        sta $D771
        lda scratch_a
        sta $D774
        lda #0
        sta $D775
        clc
        lda $D778               ; Low byte of product
        adc reg_al
        sta reg_al
        lda #0
        sta reg_ah
        lda reg_al
        sta op_result
        lda #0
        sta op_result+1
        jsr set_flags_logic
        jmp opcode_done

; ============================================================================
; $2B — SALC (D6) — Set AL from Carry (undocumented)
; ============================================================================
op_salc:
        lda flag_cf
        beq +
        lda #$FF
        sta reg_al
        jmp opcode_done
+       lda #0
        sta reg_al
        jmp opcode_done

; ============================================================================
; $2C — XLAT (D7) — Table lookup
; ============================================================================
op_xlat:
        ; AL = [DS:BX + AL]
        lda reg_bx
        clc
        adc reg_al
        sta temp32
        lda reg_bx+1
        adc #0
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read8
        sta reg_al
        jmp opcode_done

; ============================================================================
; $2F — TEST acc, imm (A8/A9)
; ============================================================================
op_test_acc_imm:
        lda i_w
        beq _tai_byte
        ; Word: AX AND imm16
        jsr fetch_word
        and reg_ax
        sta op_result
        lda scratch_a
        and reg_ax+1
        sta op_result+1
        bra _tai_flags
_tai_byte:
        jsr fetch_byte
        and reg_al
        sta op_result
        lda #0
        sta op_result+1
_tai_flags:
        lda #0
        sta flag_cf
        sta flag_of
        jsr set_flags_logic
        jmp opcode_done

; ============================================================================
; $30 — Emulator special (0F prefix)
; ============================================================================
op_emu_special:
        ; 0F prefix: 8086tiny uses 0F xx as emulator traps.
        jsr fetch_byte          ; Consume the sub-opcode
        cmp #$00
        beq _emu_sp_putchar
        cmp #$04
        beq _emu_sp_setcursor
        cmp #$05
        beq _emu_sp_scrollup
        cmp #$06
        beq _emu_sp_scrolldown
        cmp #$07
        beq _emu_sp_clearscr
        cmp #$08
        beq _emu_sp_showcur
        cmp #$09
        beq _emu_sp_hidecur
        ; 0F 01 (RTC), 0F 02/03 (disk) — ignore on our emulator
        jmp opcode_done

_emu_sp_putchar:
        ; 0F 00: Output AL via con_write_char
        lda reg_al
        cmp #$1B                ; ESC — ignore
        beq _emu_sp_ret
        jsr con_write_char
        jmp opcode_done

_emu_sp_setcursor:
        ; 0F 04: Set cursor position — DH=row, DL=col
        lda reg_dh
        sta scr_row
        lda reg_dl
        sta scr_col
        jsr cursor_update
        jmp opcode_done

_emu_sp_scrollup:
        ; 0F 05: Scroll up — AL=lines, CH/CL=start, DH/DL=end, BH=attr
        ; DEAD CODE NOTE: forced scroll (lda #SCR_ROWS / sta scr_row) was from
        ; native BIOS output testing. Reverted to standard check.
        lda reg_al
        beq _emu_sp_ret         ; 0 lines = no-op
        sta $8FD8               ; Save count (do_scr_scroll clobbers X)
_emu_sp_scrollup_loop:
        lda #SCR_ROWS
        sta scr_row
        jsr do_scr_scroll
        dec $8FD8
        bne _emu_sp_scrollup_loop
        jmp opcode_done

_emu_sp_scrolldown:
        ; 0F 06: Scroll down — not implemented yet, just ignore
        jmp opcode_done

_emu_sp_clearscr:
        ; 0F 07: Clear screen — BH=fill attribute
        lda #$93                ; PETSCII clear screen
        jsr chrout_safe
        lda #0
        sta scr_row
        sta scr_col
        jsr cursor_update
        jmp opcode_done

_emu_sp_showcur:
        ; 0F 08: Show cursor
        jsr cursor_show
        jmp opcode_done

_emu_sp_hidecur:
        ; 0F 09: Hide cursor
        jsr cursor_hide
        jmp opcode_done

_emu_sp_ret:
        jmp opcode_done

; ============================================================================
; $33 — LEA (8D)
; ============================================================================
op_lea:
        ; Load effective address: reg ← 16-bit EA offset
        ; The 16-bit EA was saved in ea_offset_lo/hi by compute_ea
        ; before segment mapping was applied.
        lda i_reg
        asl
        tax
        lda ea_offset_lo
        sta regs,x
        lda ea_offset_hi
        sta regs+1,x
        jmp opcode_done

; ============================================================================
; $05 — INC/DEC r/m (FE/FF)
; ============================================================================
op_inc_dec_rm:
        ; i_reg from modrm: 0=INC, 1=DEC, 2=CALL near indirect,
        ; 3=CALL far indirect, 4=JMP near indirect, 5=JMP far indirect,
        ; 6=PUSH r/m
        lda i_reg
        cmp #2
        bcs _idr_grp_ff

        ; INC or DEC r/m
        lda i_w
        beq _idr_rm_byte
        ; Word
        jsr read_rm16
        lda op_source
        sta op_dest
        lda op_source+1
        sta op_dest+1
        lda #1
        sta op_source
        lda #0
        sta op_source+1
        lda i_reg
        beq _idr_rm_inc_w
        ; DEC word
        lda #5
        sta extra_field         ; SUB logic for compute_of_arith
        sec
        lda op_dest
        sbc #1
        sta op_result
        lda op_dest+1
        sbc #0
        sta op_result+1
        bra _idr_rm_w_done
_idr_rm_inc_w:
        lda #0
        sta extra_field         ; ADD logic for compute_of_arith
        clc
        lda op_dest
        adc #1
        sta op_result
        lda op_dest+1
        adc #0
        sta op_result+1
_idr_rm_w_done:
        jsr write_rm16
        jsr set_flags_logic
        jsr compute_of_arith
        jmp opcode_done

_idr_rm_byte:
        jsr read_rm8
        sta op_dest
        lda #0
        sta op_dest+1
        lda #1
        sta op_source
        lda #0
        sta op_source+1
        lda i_reg
        beq _idr_rm_inc_b
        lda #5
        sta extra_field         ; SUB logic for compute_of_arith
        sec
        lda op_dest
        sbc #1
        sta op_result
        bra _idr_rm_b_done
_idr_rm_inc_b:
        lda #0
        sta extra_field         ; ADD logic for compute_of_arith
        clc
        lda op_dest
        adc #1
        sta op_result
_idr_rm_b_done:
        lda #0
        sta op_result+1
        lda op_result
        jsr write_rm8
        jsr set_flags_logic
        jsr compute_of_arith
        jmp opcode_done

_idr_grp_ff:
        ; FF group: CALL/JMP indirect, PUSH r/m
        cmp #6
        beq _idr_push_rm
        cmp #2
        beq _idr_call_ind
        cmp #4
        beq _idr_jmp_ind
        cmp #3
        beq _idr_call_far_ind
        cmp #5
        beq _idr_jmp_far_ind
        jmp opcode_done

_idr_push_rm:
        ; PUSH r/m (word)
        jsr read_rm16
        lda op_source
        sta op_result
        lda op_source+1
        sta op_result+1
        jsr push_word
        jmp opcode_done

_idr_call_ind:
        ; CALL near indirect: push IP, IP ← [r/m]
        jsr read_rm16
        lda reg_ip
        sta op_result
        lda reg_ip+1
        sta op_result+1
        jsr push_word
        lda op_source
        sta reg_ip
        lda op_source+1
        sta reg_ip+1
        jsr update_opcode_ptr
        jmp opcode_done

_idr_jmp_ind:
        ; JMP near indirect: IP ← [r/m]
        jsr read_rm16
        lda op_source
        sta reg_ip
        lda op_source+1
        sta reg_ip+1
        jsr update_opcode_ptr
        jmp opcode_done

_idr_call_far_ind:
        ; CALL far indirect: push CS, push IP, load CS:IP from [r/m]
        ; Read IP from ea_offset (cache-safe)
        lda ea_offset_lo
        sta temp32
        lda ea_offset_hi
        sta temp32+1
        lda seg_override_en
        pha
        lda seg_override
        pha
        ldx #SEG_DS_OFS
        jsr mem_read16
        lda op_source
        sta i_data0
        lda op_source+1
        sta i_data0+1
        ; Restore override for second read
        pla
        sta seg_override
        pla
        sta seg_override_en
        ; Read CS from ea_offset+2 (cache-safe)
        clc
        lda ea_offset_lo
        adc #2
        sta temp32
        lda ea_offset_hi
        adc #0
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read16
        lda op_source
        sta i_data1
        lda op_source+1
        sta i_data1+1
        ; Push CS
        lda reg_cs
        sta op_result
        lda reg_cs+1
        sta op_result+1
        jsr push_word
        ; Push IP
        lda reg_ip
        sta op_result
        lda reg_ip+1
        sta op_result+1
        jsr push_word

        ; Check if target matches INT 10h or INT 29h IVT vector
        jsr cf_check_int10
        bcs _idr_cf_int10
        jsr cf_check_int29
        bcs _idr_cf_int29

        ; No hook — set new CS:IP
        lda i_data1
        sta reg_cs
        lda i_data1+1
        sta reg_cs+1
        lda i_data0
        sta reg_ip
        lda i_data0+1
        sta reg_ip+1
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

_idr_cf_int10:
        jsr cf_pop_return
        jsr int10_handler
        jmp opcode_done
_idr_cf_int29:
        jsr cf_pop_return
        lda reg_al
        jsr con_write_char
        jmp opcode_done

_idr_jmp_far_ind:
        ; JMP far indirect: load CS:IP from [r/m] (cache-safe)
        ; Read IP from ea_offset
        lda ea_offset_lo
        sta temp32
        lda ea_offset_hi
        sta temp32+1
        lda seg_override_en
        pha
        lda seg_override
        pha
        ldx #SEG_DS_OFS
        jsr mem_read16
        lda op_source
        sta i_data0
        lda op_source+1
        sta i_data0+1
        ; Restore override for second read
        pla
        sta seg_override
        pla
        sta seg_override_en
        ; Read CS from ea_offset+2
        clc
        lda ea_offset_lo
        adc #2
        sta temp32
        lda ea_offset_hi
        adc #0
        sta temp32+1
        ldx #SEG_DS_OFS
        jsr mem_read16
        lda op_source
        sta reg_cs
        lda op_source+1
        sta reg_cs+1
        lda i_data0
        sta reg_ip
        lda i_data0+1
        sta reg_ip+1
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        jmp opcode_done

; ============================================================================
; $06 — GRP F6/F7: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV
; ============================================================================
op_grp_f6f7:
        ; i_reg from modrm: 0=TEST, 2=NOT, 3=NEG, 4=MUL, 5=IMUL, 6=DIV, 7=IDIV
        lda i_reg
        asl
        tax
        jmp (_grp_f6_tbl,x)

_grp_f6_tbl:
        .word _gf_test          ; 0
        .word _gf_test          ; 1 (undefined, treat as test)
        .word _gf_not           ; 2
        .word _gf_neg           ; 3
        .word _gf_mul           ; 4
        .word _gf_imul          ; 5
        .word _gf_div           ; 6
        .word _gf_idiv          ; 7

_gf_test:
        ; TEST r/m, imm
        lda i_w
        beq _gft_byte
        jsr read_rm16
        jsr fetch_word
        and op_source
        sta op_result
        lda scratch_a
        and op_source+1
        sta op_result+1
        bra _gft_flags
_gft_byte:
        jsr read_rm8
        sta scratch_a
        jsr fetch_byte
        and scratch_a
        sta op_result
        lda #0
        sta op_result+1
_gft_flags:
        lda #0
        sta flag_cf
        sta flag_of
        jsr set_flags_logic
        jmp opcode_done

_gf_not:
        lda i_w
        beq _gfn_byte
        jsr read_rm16
        lda op_source
        eor #$FF
        sta op_result
        lda op_source+1
        eor #$FF
        sta op_result+1
        jsr write_rm16
        jmp opcode_done
_gfn_byte:
        jsr read_rm8
        eor #$FF
        jsr write_rm8
        jmp opcode_done

_gf_neg:
        lda #5
        sta extra_field         ; SUB logic for compute_of_arith
        lda i_w
        beq _gfng_byte
        jsr read_rm16
        ; op_dest = 0 (the minuend for 0 - source)
        lda #0
        sta op_dest
        sta op_dest+1
        ; result = 0 - source
        sec
        lda #0
        sbc op_source
        sta op_result
        lda #0
        sbc op_source+1
        sta op_result+1
        ; CF = (source != 0)
        lda op_source
        ora op_source+1
        beq +
        lda #1
+       sta flag_cf
        jsr write_rm16
        jsr set_flags_logic
        jsr compute_of_arith
        jmp opcode_done
_gfng_byte:
        jsr read_rm8
        sta op_source
        lda #0
        sta op_source+1
        sta op_dest
        sta op_dest+1
        sec
        lda #0
        sbc op_source
        sta op_result
        lda #0
        sta op_result+1
        lda op_source
        beq +
        lda #1
+       sta flag_cf
        lda op_result
        jsr write_rm8
        jsr set_flags_logic
        jsr compute_of_arith
        jmp opcode_done

_gf_mul:
        ; Unsigned multiply: AX = AL * r/m8 or DX:AX = AX * r/m16
        lda i_w
        beq _gfm_byte
        jsr read_rm16
        ; AX * r/m16 using hardware multiplier
        lda reg_ax
        sta $D770
        lda reg_ax+1
        sta $D771
        lda op_source
        sta $D774
        lda op_source+1
        sta $D775
        ; 32-bit result at $D778
        lda $D778
        sta reg_ax
        lda $D779
        sta reg_ax+1
        lda $D77A
        sta reg_dx
        lda $D77B
        sta reg_dx+1
        ; CF=OF=1 if DX != 0
        lda reg_dx
        ora reg_dx+1
        beq +
        lda #1
+       sta flag_cf
        sta flag_of
        jmp opcode_done
_gfm_byte:
        jsr read_rm8
        sta $D774
        lda #0
        sta $D775
        lda reg_al
        sta $D770
        lda #0
        sta $D771
        lda $D778
        sta reg_al
        lda $D779
        sta reg_ah
        lda reg_ah
        beq +
        lda #1
+       sta flag_cf
        sta flag_of
        jmp opcode_done

_gf_imul:
        ; Signed multiply: AL * r/m8 → AX  or  AX * r/m16 → DX:AX
        lda i_w
        beq _gfim_byte
        ; Word: AX * r/m16
        jsr read_rm16
        ; Detect signs
        lda #0
        sta $8F72               ; Sign flag: 0=positive, 1=negative result
        lda reg_ax+1
        bpl _gfim_w_src
        ; Negate AX
        lda #1
        eor $8F72
        sta $8F72
        sec
        lda #0
        sbc reg_ax
        sta reg_ax
        lda #0
        sbc reg_ax+1
        sta reg_ax+1
_gfim_w_src:
        lda op_source+1
        bpl _gfim_w_do
        ; Negate source
        lda #1
        eor $8F72
        sta $8F72
        sec
        lda #0
        sbc op_source
        sta op_source
        lda #0
        sbc op_source+1
        sta op_source+1
_gfim_w_do:
        ; Unsigned multiply via hardware multiplier
        lda reg_ax
        sta $D770
        lda reg_ax+1
        sta $D771
        lda op_source
        sta $D774
        lda op_source+1
        sta $D775
        lda $D778
        sta reg_ax
        lda $D779
        sta reg_ax+1
        lda $D77A
        sta reg_dx
        lda $D77B
        sta reg_dx+1
        ; Apply sign to DX:AX if needed
        lda $8F72
        beq _gfim_w_flags
        ; Negate DX:AX
        sec
        lda #0
        sbc reg_ax
        sta reg_ax
        lda #0
        sbc reg_ax+1
        sta reg_ax+1
        lda #0
        sbc reg_dx
        sta reg_dx
        lda #0
        sbc reg_dx+1
        sta reg_dx+1
_gfim_w_flags:
        ; CF=OF=1 if DX is sign extension of AX (i.e., upper half matters)
        lda reg_ax+1
        bpl _gfim_w_pos
        ; AX is negative: DX should be $FFFF for no overflow
        lda reg_dx
        and reg_dx+1
        cmp #$FF
        beq _gfim_w_noof
        bra _gfim_w_of
_gfim_w_pos:
        ; AX is positive: DX should be $0000 for no overflow
        lda reg_dx
        ora reg_dx+1
        beq _gfim_w_noof
_gfim_w_of:
        lda #1
        sta flag_cf
        sta flag_of
        jmp opcode_done
_gfim_w_noof:
        lda #0
        sta flag_cf
        sta flag_of
        jmp opcode_done

_gfim_byte:
        ; Byte: AL * r/m8 → AX
        jsr read_rm8
        sta op_source
        lda #0
        sta $8F72
        lda reg_al
        bpl _gfim_b_src
        lda #1
        sta $8F72
        ; Negate AL
        sec
        lda #0
        sbc reg_al
        sta reg_al
_gfim_b_src:
        lda op_source
        bpl _gfim_b_do
        lda #1
        eor $8F72
        sta $8F72
        sec
        lda #0
        sbc op_source
        sta op_source
_gfim_b_do:
        ; Unsigned multiply
        lda reg_al
        sta $D770
        lda #0
        sta $D771
        lda op_source
        sta $D774
        lda #0
        sta $D775
        lda $D778
        sta reg_al
        lda $D779
        sta reg_ah
        ; Apply sign
        lda $8F72
        beq _gfim_b_flags
        sec
        lda #0
        sbc reg_al
        sta reg_al
        lda #0
        sbc reg_ah
        sta reg_ah
_gfim_b_flags:
        ; CF=OF=1 if AH is not sign extension of AL
        lda reg_al
        bpl _gfim_b_pos
        lda reg_ah
        cmp #$FF
        beq _gfim_b_noof
        bra _gfim_b_of
_gfim_b_pos:
        lda reg_ah
        beq _gfim_b_noof
_gfim_b_of:
        lda #1
        sta flag_cf
        sta flag_of
        jmp opcode_done
_gfim_b_noof:
        lda #0
        sta flag_cf
        sta flag_of
        jmp opcode_done

_gf_div:
        ; Unsigned divide: AX / r/m8 → AL=quot, AH=rem
        ; or DX:AX / r/m16 → AX=quot, DX=rem
        lda i_w
        beq _gfd_byte
        jsr read_rm16
        lda op_source
        ora op_source+1
        beq _gfd_div0
        ; DX:AX / r/m16 using software division
        lda reg_ax
        sta div_dividend
        lda reg_ax+1
        sta div_dividend+1
        lda reg_dx
        sta div_dividend+2
        lda reg_dx+1
        sta div_dividend+3
        lda op_source
        sta div_divisor
        lda op_source+1
        sta div_divisor+1
        jsr div_32by16
        ; Check overflow: quotient must fit in 16 bits
        lda div_quotient+2
        ora div_quotient+3
        bne _gfd_div0           ; Overflow → INT 0
        lda div_quotient
        sta reg_ax
        lda div_quotient+1
        sta reg_ax+1
        lda div_remainder
        sta reg_dx
        lda div_remainder+1
        sta reg_dx+1
        jmp opcode_done
_gfd_byte:
        jsr read_rm8
        beq _gfd_div0
        sta div_divisor
        lda #0
        sta div_divisor+1
        lda reg_al
        sta div_dividend
        lda reg_ah
        sta div_dividend+1
        lda #0
        sta div_dividend+2
        sta div_dividend+3
        jsr div_16by8
        ; Check overflow: quotient must fit in 8 bits
        lda div_quotient+1
        bne _gfd_div0
        lda div_quotient
        sta reg_al              ; Quotient
        lda div_remainder
        sta reg_ah              ; Remainder
        jmp opcode_done
_gfd_div0:
        inc $8F14               ; Count divide-by-zero errors
        lda #0
        jsr do_sw_interrupt     ; INT 0
        jsr compute_cs_base
        jmp opcode_done

_gf_idiv:
        ; Signed divide: AX / r/m8 → AL=quot, AH=rem
        ; or DX:AX / r/m16 → AX=quot, DX=rem
        ; Quotient sign = dividend sign XOR divisor sign
        ; Remainder sign = dividend sign
        lda i_w
        beq _gfid_byte

        ; Word: DX:AX / r/m16
        jsr read_rm16
        lda op_source
        ora op_source+1
        beq _gfd_div0           ; Divide by zero

        lda #0
        sta $8F72               ; Quotient sign
        sta $8F73               ; Remainder sign (= dividend sign)

        ; Check dividend sign (DX:AX)
        lda reg_dx+1
        bpl _gfid_w_divsrc
        ; Negate DX:AX
        lda #1
        sta $8F72
        sta $8F73
        sec
        lda #0
        sbc reg_ax
        sta reg_ax
        lda #0
        sbc reg_ax+1
        sta reg_ax+1
        lda #0
        sbc reg_dx
        sta reg_dx
        lda #0
        sbc reg_dx+1
        sta reg_dx+1

_gfid_w_divsrc:
        ; Check divisor sign
        lda op_source+1
        bpl _gfid_w_do
        ; Negate divisor
        lda #1
        eor $8F72
        sta $8F72               ; Flip quotient sign
        sec
        lda #0
        sbc op_source
        sta op_source
        lda #0
        sbc op_source+1
        sta op_source+1

_gfid_w_do:
        ; Unsigned divide
        lda reg_ax
        sta div_dividend
        lda reg_ax+1
        sta div_dividend+1
        lda reg_dx
        sta div_dividend+2
        lda reg_dx+1
        sta div_dividend+3
        lda op_source
        sta div_divisor
        lda op_source+1
        sta div_divisor+1
        jsr div_32by16

        ; Signed overflow check: quotient must fit in -32768..32767
        lda div_quotient+2
        ora div_quotient+3
        bne _gfd_div0           ; Absolute quotient > 16 bits
        lda $8F72
        beq _gfid_w_posq
        ; Negative quotient: max absolute value is 32768 ($8000)
        lda div_quotient+1
        cmp #$80
        beq _gfid_w_exact_neg
        bcs _gfd_div0           ; > $8000 → overflow
        bra _gfid_w_apply
_gfid_w_exact_neg:
        lda div_quotient
        bne _gfd_div0           ; > $8000 → overflow
        bra _gfid_w_apply
_gfid_w_posq:
        ; Positive quotient: max is 32767 ($7FFF)
        lda div_quotient+1
        bmi _gfd_div0           ; >= $8000 → overflow

_gfid_w_apply:
        ; Apply quotient sign
        lda div_quotient
        sta reg_ax
        lda div_quotient+1
        sta reg_ax+1
        lda $8F72
        beq _gfid_w_rem
        ; Negate quotient
        sec
        lda #0
        sbc reg_ax
        sta reg_ax
        lda #0
        sbc reg_ax+1
        sta reg_ax+1

_gfid_w_rem:
        ; Apply remainder sign (= dividend sign)
        lda div_remainder
        sta reg_dx
        lda div_remainder+1
        sta reg_dx+1
        lda $8F73
        beq _gfid_w_done
        sec
        lda #0
        sbc reg_dx
        sta reg_dx
        lda #0
        sbc reg_dx+1
        sta reg_dx+1
_gfid_w_done:
        jmp opcode_done

_gfid_byte:
        ; Byte: AX / r/m8 → AL=quot, AH=rem
        jsr read_rm8
        beq _gfd_div0
        sta op_source

        lda #0
        sta $8F72               ; Quotient sign
        sta $8F73               ; Remainder sign

        ; Check dividend sign (AX)
        lda reg_ah
        bpl _gfid_b_divsrc
        lda #1
        sta $8F72
        sta $8F73
        ; Negate AX
        sec
        lda #0
        sbc reg_al
        sta reg_al
        lda #0
        sbc reg_ah
        sta reg_ah

_gfid_b_divsrc:
        lda op_source
        bpl _gfid_b_do
        lda #1
        eor $8F72
        sta $8F72
        sec
        lda #0
        sbc op_source
        sta op_source

_gfid_b_do:
        lda reg_al
        sta div_dividend
        lda reg_ah
        sta div_dividend+1
        lda #0
        sta div_dividend+2
        sta div_dividend+3
        lda op_source
        sta div_divisor
        lda #0
        sta div_divisor+1
        jsr div_16by8

        ; Signed overflow: quotient must fit -128..127
        lda div_quotient+1
        bne _gfd_div0           ; > 8 bits
        lda $8F72
        beq _gfid_b_posq
        ; Negative: max absolute is 128 ($80)
        lda div_quotient
        cmp #$81
        bcs _gfd_div0
        bra _gfid_b_apply
_gfid_b_posq:
        lda div_quotient
        cmp #$80
        bcs _gfd_div0           ; >= 128 → overflow

_gfid_b_apply:
        lda div_quotient
        sta reg_al
        lda $8F72
        beq _gfid_b_rem
        sec
        lda #0
        sbc reg_al
        sta reg_al
_gfid_b_rem:
        lda div_remainder
        sta reg_ah
        lda $8F73
        beq _gfid_b_done
        sec
        lda #0
        sbc reg_ah
        sta reg_ah
_gfid_b_done:
        jmp opcode_done

; ============================================================================
; Software Division Routines
; ============================================================================

; 16-bit / 8-bit unsigned division (shift-and-subtract)
; Input:  div_dividend (16-bit in +0/+1), div_divisor (8-bit in +0)
; Output: div_quotient (16-bit), div_remainder (8-bit)
div_16by8:
        lda #$00
        sta div_quotient
        sta div_quotient+1
        sta div_remainder
        sta div_remainder+1

        ldx #16
_d8_loop:
        ; Shift dividend left, MSB into remainder
        asl div_dividend
        rol div_dividend+1
        rol div_remainder
        rol div_remainder+1     ; Must shift high byte too

        ; Shift quotient left
        asl div_quotient
        rol div_quotient+1

        ; Try subtract divisor from remainder (16-bit remainder vs 8-bit divisor)
        sec
        lda div_remainder
        sbc div_divisor
        tay
        lda div_remainder+1
        sbc #0
        bcc _d8_no_sub

        ; Fits: store new remainder, set quotient bit
        sta div_remainder+1
        sty div_remainder
        lda div_quotient
        ora #$01
        sta div_quotient

_d8_no_sub:
        dex
        bne _d8_loop
        rts

; 32-bit / 16-bit unsigned division (shift-and-subtract)
; Input:  div_dividend (32-bit), div_divisor (16-bit)
; Output: div_quotient (32-bit), div_remainder (16-bit)
div_32by16:
        lda #$00
        sta div_quotient
        sta div_quotient+1
        sta div_quotient+2
        sta div_quotient+3
        sta div_remainder
        sta div_remainder+1
        sta $8F0E               ; 17th bit of remainder (overflow byte)

        ldx #32
_d16_loop:
        ; Shift dividend left, MSB into remainder
        asl div_dividend
        rol div_dividend+1
        rol div_dividend+2
        rol div_dividend+3
        rol div_remainder
        rol div_remainder+1
        rol $8F0E               ; Shift 17th bit

        ; Shift quotient left
        asl div_quotient
        rol div_quotient+1
        rol div_quotient+2
        rol div_quotient+3

        ; Try subtract: remainder - divisor (with 17th bit)
        sec
        lda div_remainder
        sbc div_divisor
        sta scratch_a           ; Tentative low byte
        lda div_remainder+1
        sbc div_divisor+1
        sta scratch_b           ; Tentative high byte
        lda $8F0E
        sbc #0
        bcc _d16_no_sub         ; Doesn't fit (17th bit borrow)

        ; Fits: commit the subtraction
        lda scratch_a
        sta div_remainder
        lda scratch_b
        sta div_remainder+1
        lda #0
        sta $8F0E               ; Clear 17th bit
        lda div_quotient
        ora #$01
        sta div_quotient

_d16_no_sub:
        dex
        bne _d16_loop
        rts

