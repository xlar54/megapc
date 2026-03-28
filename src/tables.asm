; ============================================================================
; tables.asm — Opcode Dispatch & Decode Tables
; ============================================================================
;
; These tables are generated from the BIOS binary at startup (init_tables).
; However, the opcode_dispatch table maps raw opcodes to handler indices
; and is defined here in the emulator (not in the BIOS).
;
; Handler index → opcode_jump_tbl entry in decode.asm
;
; Key fixes from old branch debugging:
;   - Unimplemented opcodes (6x, D8–DF, F0, F1, F4) → $31 (op_nop_unimpl)
;     NOT $00 (op_cond_jump) which caused IP corruption
;   - Prefixes (26, 2E, 36, 3E, F0, F2, F3) now handled in main loop,
;     not in dispatch table — they never reach here
;   - IRET (CF) has its own handler $34, separate from RET
;   - MOV reg,r/m (88–8B) separate handler $32
;   - LEA (8D) separate handler $33
;
; Handler IDs:
;   $00 op_cond_jump       $01 op_mov_reg_imm      $02 op_inc_dec_r16
;   $03 op_push_r16        $04 op_pop_r16           $05 op_inc_dec_rm
;   $06 op_grp_f6f7        $07 op_alu_imm_acc       $08 op_alu_imm_rm
;   $09 op_alu_reg_rm      $0A op_mov_sreg           $0B op_mov_acc_mem
;   $0C op_shift_rot       $0D op_loop               $0E op_jmp_call
;   $0F op_test_rm         $10 op_xchg_ax            $11 op_movs_stos
;   $12 op_cmps_scas       $13 op_ret                $14 op_mov_rm_imm
;   $15 op_in              $16 op_out                $17 op_rep
;   $18 op_xchg_rm         $19 op_push_seg           $1A op_pop_seg
;   $1B op_seg_override    $1C op_daa_das            $1D op_aaa_aas
;   $1E op_cbw             $1F op_cwd                $20 op_call_far
;   $21 op_pushf           $22 op_popf               $23 op_sahf
;   $24 op_lahf            $25 op_les_lds            $26 op_int3
;   $27 op_int_imm         $28 op_into               $29 op_aam
;   $2A op_aad             $2B op_salc               $2C op_xlat
;   $2D op_cmc             $2E op_clc_stc_etc        $2F op_test_acc_imm
;   $30 op_emu_special     $31 op_nop_unimpl         $32 op_mov_reg_rm
;   $33 op_lea             $34 op_int_ret

opcode_dispatch:
        ; 0x row: ALU reg/rm, ALU acc/imm, PUSH/POP seg, seg override, prefix
        ;         00    01    02    03    04    05    06    07
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $19,  $1A  ; ADD r/m, ADD acc, PUSH ES, POP ES
        ;         08    09    0A    0B    0C    0D    0E    0F
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $19,  $30  ; OR r/m, OR acc, PUSH CS, 0F=emu_special

        ; 1x row: ADC, SBB group
        ;         10    11    12    13    14    15    16    17
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $19,  $1A  ; ADC r/m, ADC acc, PUSH SS, POP SS
        ;         18    19    1A    1B    1C    1D    1E    1F
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $19,  $1A  ; SBB r/m, SBB acc, PUSH DS, POP DS

        ; 2x row: AND, SUB, seg overrides, DAA/DAS
        ;         20    21    22    23    24    25    26    27
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $1B,  $1C  ; AND r/m, AND acc, ES:, DAA
        ;         28    29    2A    2B    2C    2D    2E    2F
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $1B,  $1C  ; SUB r/m, SUB acc, CS:, DAS

        ; 3x row: XOR, CMP, seg overrides, AAA/AAS
        ;         30    31    32    33    34    35    36    37
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $1B,  $1D  ; XOR r/m, XOR acc, SS:, AAA
        ;         38    39    3A    3B    3C    3D    3E    3F
        .byte   $09,  $09,  $09,  $09,  $07,  $07,  $1B,  $1D  ; CMP r/m, CMP acc, DS:, AAS

        ; 4x row: INC/DEC r16
        .byte   $02,  $02,  $02,  $02,  $02,  $02,  $02,  $02  ; INC AX–DI
        .byte   $02,  $02,  $02,  $02,  $02,  $02,  $02,  $02  ; DEC AX–DI

        ; 5x row: PUSH/POP r16
        .byte   $03,  $03,  $03,  $03,  $03,  $03,  $03,  $03  ; PUSH AX–DI
        .byte   $04,  $04,  $04,  $04,  $04,  $04,  $04,  $04  ; POP AX–DI

        ; 6x row: 80186 extensions
        .byte   $35,  $36,  $31,  $31,  $31,  $31,  $31,  $31  ; PUSHA, POPA, rest unimpl
        .byte   $37,  $31,  $38,  $31,  $31,  $31,  $31,  $31  ; PUSH imm16, ?, PUSH imm8, rest unimpl

        ; 7x row: Conditional jumps
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00  ; JO–JA
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00  ; JS–JG

        ; 8x row: ALU imm, TEST, XCHG, MOV reg/rm, MOV sreg, LEA
        ;         80    81    82    83    84    85    86    87
        .byte   $08,  $08,  $08,  $08,  $0F,  $0F,  $18,  $18  ; ALU imm, TEST, XCHG
        ;         88    89    8A    8B    8C    8D    8E    8F
        .byte   $32,  $32,  $32,  $32,  $0A,  $33,  $0A,  $31  ; MOV r/m, MOV sreg, LEA, (8F=POP r/m)

        ; 9x row: XCHG AX, CBW, CWD, CALL far, WAIT, PUSHF/POPF, SAHF/LAHF
        ;         90    91    92    93    94    95    96    97
        .byte   $10,  $10,  $10,  $10,  $10,  $10,  $10,  $10  ; NOP/XCHG AX,r16
        ;         98    99    9A    9B    9C    9D    9E    9F
        .byte   $1E,  $1F,  $20,  $31,  $21,  $22,  $23,  $24  ; CBW, CWD, CALL far, WAIT, PUSHF, POPF, SAHF, LAHF

        ; Ax row: MOV acc/mem, string ops, TEST acc/imm
        ;         A0    A1    A2    A3    A4    A5    A6    A7
        .byte   $0B,  $0B,  $0B,  $0B,  $11,  $11,  $12,  $12  ; MOV acc, MOVS, CMPS
        ;         A8    A9    AA    AB    AC    AD    AE    AF
        .byte   $2F,  $2F,  $11,  $11,  $11,  $11,  $12,  $12  ; TEST acc, STOS, LODS, SCAS

        ; Bx row: MOV reg, imm
        .byte   $01,  $01,  $01,  $01,  $01,  $01,  $01,  $01  ; MOV AL–BH, imm8
        .byte   $01,  $01,  $01,  $01,  $01,  $01,  $01,  $01  ; MOV AX–DI, imm16

        ; Cx row: Shift, RET, LES/LDS, MOV imm, ENTER/LEAVE, INT, IRET
        ;         C0    C1    C2    C3    C4    C5    C6    C7
        .byte   $0C,  $0C,  $13,  $13,  $25,  $25,  $14,  $14  ; Shift, RET imm, RET, LES, LDS, MOV rm/imm
        ;         C8    C9    CA    CB    CC    CD    CE    CF
        .byte   $31,  $31,  $13,  $13,  $26,  $27,  $28,  $34  ; ENTER, LEAVE, RETF, INT3, INT, INTO, IRET

        ; Dx row: Shift/rotate, AAM, AAD, SALC, XLAT, FPU escape
        ;         D0    D1    D2    D3    D4    D5    D6    D7
        .byte   $0C,  $0C,  $0C,  $0C,  $29,  $2A,  $2B,  $2C  ; Shifts, AAM, AAD, SALC, XLAT
        ;         D8    D9    DA    DB    DC    DD    DE    DF
        .byte   $31,  $31,  $31,  $31,  $31,  $31,  $31,  $31  ; FPU ESC (all unimpl)

        ; Ex row: LOOP, IN/OUT, JMP/CALL
        ;         E0    E1    E2    E3    E4    E5    E6    E7
        .byte   $0D,  $0D,  $0D,  $0D,  $15,  $15,  $16,  $16  ; LOOPNZ, LOOPZ, LOOP, JCXZ, IN, OUT
        ;         E8    E9    EA    EB    EC    ED    EE    EF
        .byte   $0E,  $0E,  $0E,  $0E,  $15,  $15,  $16,  $16  ; CALL, JMP, JMP far, JMP short, IN/OUT DX

        ; Fx row: LOCK, REP, HLT, CMC, GRP F6/F7, flag ops, INC/DEC
        ;         F0    F1    F2    F3    F4    F5    F6    F7
        .byte   $31,  $31,  $17,  $17,  $31,  $2D,  $06,  $06  ; LOCK, ?, REP, REPZ, HLT, CMC, GRP1
        ;         F8    F9    FA    FB    FC    FD    FE    FF
        .byte   $2E,  $2E,  $2E,  $2E,  $2E,  $2E,  $05,  $05  ; CLC,STC,CLI,STI,CLD,STD, INC/DEC rm

; ============================================================================
; extra_field_tbl — Extra field values per opcode
; ============================================================================
; This encodes sub-operation info:
;   For ALU opcodes (00–3F): bits 5–3 of opcode = ALU op (0–7)
;   For segment push/pop: segment register offset
;   For conditional jumps: condition code
;   For INC/DEC r16: register index
;   etc.
;
; Corrected from debugging: Fx row had all zeros — now fixed for
; Corrected from debugging: Fx row was all zeros in old branch — now fixed for
; CLC(F8), STC(F9), CLI(FA), STI(FB), CLD(FC), STD(FD)
; (These values encode which flag to modify)

extra_field_tbl:
        ; 0x: ADD=0, PUSH ES, POP ES
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $10,  $10
        .byte   $01,  $01,  $01,  $01,  $01,  $01,  $12,  $00

        ; 1x: ADC=2, SBB=3, PUSH/POP SS/DS
        .byte   $02,  $02,  $02,  $02,  $02,  $02,  $14,  $14
        .byte   $03,  $03,  $03,  $03,  $03,  $03,  $16,  $16

        ; 2x: AND=4, SUB=5, ES: override, DAA/DAS
        .byte   $04,  $04,  $04,  $04,  $04,  $04,  $10,  $00
        .byte   $05,  $05,  $05,  $05,  $05,  $05,  $12,  $00

        ; 3x: XOR=6, CMP=7, SS: DS: override, AAA/AAS
        .byte   $06,  $06,  $06,  $06,  $06,  $06,  $14,  $00
        .byte   $07,  $07,  $07,  $07,  $07,  $07,  $16,  $00

        ; 4x: INC r16 = ADD(0), DEC r16 = SUB(5) — for compute_of_arith
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $05,  $05,  $05,  $05,  $05,  $05,  $05,  $05

        ; 5x: PUSH r16 (0–7), POP r16 (0–7)
        .byte   $00,  $01,  $02,  $03,  $04,  $05,  $06,  $07
        .byte   $00,  $01,  $02,  $03,  $04,  $05,  $06,  $07

        ; 6x: unimplemented (80186)
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; 7x: Jcc — condition code 0–15
        .byte   $00,  $01,  $02,  $03,  $04,  $05,  $06,  $07
        .byte   $08,  $09,  $0A,  $0B,  $0C,  $0D,  $0E,  $0F

        ; 8x: ALU imm (sub-op from modrm reg), TEST, XCHG, MOV
        .byte   $00,  $00,  $00,  $00,  $05,  $05,  $00,  $00
        .byte   $08,  $08,  $08,  $08,  $00,  $00,  $00,  $00

        ; 9x: XCHG AX (reg 0–7), CBW, CWD, CALL far, WAIT, PUSHF, POPF, SAHF, LAHF
        .byte   $00,  $01,  $02,  $03,  $04,  $05,  $06,  $07
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; Ax: MOV acc/mem, string ops, TEST acc
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; Bx: MOV reg imm (not needed — reg from opcode)
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; Cx: Shift imm, RET, RETF, LES, LDS, INT, IRET
        .byte   $01,  $01,  $00,  $00,  $10,  $16,  $00,  $00
        .byte   $00,  $00,  $01,  $01,  $00,  $00,  $00,  $03

        ; Dx: Shift/rotate (1/CL), AAM, AAD, SALC, XLAT, FPU escape
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; Ex: LOOP, IN/OUT, JMP/CALL
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00

        ; Fx: LOCK, REP, HLT, CMC, GRP, CLC/STC/CLI/STI/CLD/STD, INC/DEC rm
        ; CORRECTED: was all zeros in old branch!
        .byte   $00,  $00,  $00,  $00,  $00,  $00,  $00,  $00
        .byte   $00,  $01,  $0C,  $0D,  $0E,  $0F,  $00,  $00
        ;       CLC   STC   CLI   STI   CLD   STD   FE    FF

; ============================================================================
; i_w_tbl — Word/byte mode per opcode
; ============================================================================
; 0 = byte, 1 = word
; For ALU opcodes: bit 0 of opcode = i_w
; For most others: derived from opcode encoding
i_w_tbl:
        ; 0x: ALU reg/rm — bit 0 selects byte/word
        .byte   0, 1, 0, 1, 0, 1, 1, 1,  0, 1, 0, 1, 0, 1, 1, 0  ; 00-0F
        .byte   0, 1, 0, 1, 0, 1, 1, 1,  0, 1, 0, 1, 0, 1, 1, 1  ; 10-1F
        .byte   0, 1, 0, 1, 0, 1, 0, 0,  0, 1, 0, 1, 0, 1, 0, 0  ; 20-2F
        .byte   0, 1, 0, 1, 0, 1, 0, 0,  0, 1, 0, 1, 0, 1, 0, 0  ; 30-3F
        ; 4x: INC/DEC r16 = word
        .byte   1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1  ; 40-4F
        ; 5x: PUSH/POP r16 = word
        .byte   1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1  ; 50-5F
        ; 6x: unimplemented
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 60-6F
        ; 7x: Jcc (byte displacement, but operand is N/A)
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 70-7F
        ; 8x: ALU imm, TEST, XCHG, MOV
        .byte   0, 1, 0, 1, 0, 1, 0, 1,  0, 1, 0, 1, 1, 1, 1, 1  ; 80-8F
        ; 9x: XCHG=word, CBW, CWD, etc
        .byte   1, 1, 1, 1, 1, 1, 1, 1,  0, 0, 1, 0, 1, 1, 0, 0  ; 90-9F
        ; Ax: MOV acc/mem, string ops, TEST
        .byte   0, 1, 0, 1, 0, 1, 0, 1,  0, 1, 0, 1, 0, 1, 0, 1  ; A0-AF
        ; Bx: MOV reg,imm — B0-B7=byte, B8-BF=word
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  1, 1, 1, 1, 1, 1, 1, 1  ; B0-BF
        ; Cx: shift, RET, LES/LDS, MOV rm/imm, etc
        .byte   0, 1, 1, 1, 1, 1, 0, 1,  0, 0, 1, 1, 0, 0, 0, 1  ; C0-CF
        ; Dx: shift, AAM, AAD, SALC, XLAT, FPU
        .byte   0, 1, 0, 1, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; D0-DF
        ; Ex: LOOP, IN/OUT, JMP/CALL
        .byte   0, 0, 0, 0, 0, 1, 0, 1,  1, 1, 1, 0, 0, 1, 0, 1  ; E0-EF
        ; Fx: LOCK, REP, HLT, CMC, GRP F6/F7, flag ops, INC/DEC rm
        .byte   0, 0, 0, 0, 0, 0, 0, 1,  0, 0, 0, 0, 0, 0, 0, 1  ; F0-FF

; ============================================================================
; i_d_tbl — Direction per opcode
; ============================================================================
; 0 = reg is source (dest=r/m), 1 = reg is dest (source=r/m)
; For ALU opcodes: bit 1 of opcode = i_d
i_d_tbl:
        ; 0x: ALU — bit 1 selects direction
        .byte   0, 0, 1, 1, 0, 0, 0, 0,  0, 0, 1, 1, 0, 0, 0, 0  ; 00-0F
        .byte   0, 0, 1, 1, 0, 0, 0, 0,  0, 0, 1, 1, 0, 0, 0, 0  ; 10-1F
        .byte   0, 0, 1, 1, 0, 0, 0, 0,  0, 0, 1, 1, 0, 0, 0, 0  ; 20-2F
        .byte   0, 0, 1, 1, 0, 0, 0, 0,  0, 0, 1, 1, 0, 0, 0, 0  ; 30-3F
        ; 4x-7x: N/A (single operand or no r/m)
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 40-4F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 50-5F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 60-6F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 70-7F
        ; 8x: ALU imm=0, TEST=0, XCHG=0, MOV 88/89=0 8A/8B=1, sreg
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 1, 1, 0, 1, 1, 0  ; 80-8F
        ; 9x-Fx: mostly 0
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 90-9F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; A0-AF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; B0-BF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; C0-CF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; D0-DF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; E0-EF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; F0-FF

; ============================================================================
; i_mod_sz_tbl — ModR/M needed per opcode
; ============================================================================
; 0 = no modrm, nonzero = has modrm byte
i_mod_sz_tbl:
        ; 0x: ALU reg/rm all have modrm
        .byte   1, 1, 1, 1, 0, 0, 0, 0,  1, 1, 1, 1, 0, 0, 0, 0  ; 00-0F
        .byte   1, 1, 1, 1, 0, 0, 0, 0,  1, 1, 1, 1, 0, 0, 0, 0  ; 10-1F
        .byte   1, 1, 1, 1, 0, 0, 0, 0,  1, 1, 1, 1, 0, 0, 0, 0  ; 20-2F
        .byte   1, 1, 1, 1, 0, 0, 0, 0,  1, 1, 1, 1, 0, 0, 0, 0  ; 30-3F
        ; 4x-7x: none
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 40-4F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 50-5F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 60-6F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 70-7F
        ; 8x: 80-8F all have modrm
        .byte   1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1  ; 80-8F
        ; 9x: none
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 90-9F
        ; Ax: none
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; A0-AF
        ; Bx: none
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; B0-BF
        ; Cx: C0/C1 shift=modrm, C4/C5 LES/LDS=modrm, C6/C7 MOV=modrm
        .byte   1, 1, 0, 0, 1, 1, 1, 1,  0, 0, 0, 0, 0, 0, 0, 0  ; C0-CF
        ; Dx: D0-D3 shift=modrm, D8-DF FPU=modrm(ignored)
        .byte   1, 1, 1, 1, 0, 0, 0, 0,  1, 1, 1, 1, 1, 1, 1, 1  ; D0-DF
        ; Ex: none
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; E0-EF
        ; Fx: F6/F7 GRP=modrm, FE/FF=modrm
        .byte   0, 0, 0, 0, 0, 0, 1, 1,  0, 0, 0, 0, 0, 0, 1, 1  ; F0-FF

; ============================================================================
; set_flags_tbl — Which flags to set after each opcode
; ============================================================================
; 0 = no flags, 1 = arithmetic flags, 2 = logic flags
; This is a simplified version; full version comes from BIOS tables
set_flags_tbl:
        ; 0x-3x: ALU = arithmetic flags
        .byte   1, 1, 1, 1, 1, 1, 0, 0,  1, 1, 1, 1, 1, 1, 0, 0  ; 00-0F
        .byte   1, 1, 1, 1, 1, 1, 0, 0,  1, 1, 1, 1, 1, 1, 0, 0  ; 10-1F
        .byte   2, 2, 2, 2, 2, 2, 0, 0,  1, 1, 1, 1, 1, 1, 0, 0  ; 20-2F
        .byte   2, 2, 2, 2, 2, 2, 0, 0,  1, 1, 1, 1, 1, 1, 0, 0  ; 30-3F
        ; 4x: INC/DEC
        .byte   1, 1, 1, 1, 1, 1, 1, 1,  1, 1, 1, 1, 1, 1, 1, 1  ; 40-4F
        ; 5x-Fx: mostly 0 (handlers set their own flags)
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 50-5F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 60-6F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 70-7F
        .byte   1, 1, 1, 1, 2, 2, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 80-8F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; 90-9F
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  2, 2, 0, 0, 0, 0, 0, 0  ; A0-AF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; B0-BF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; C0-CF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; D0-DF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; E0-EF
        .byte   0, 0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0, 0  ; F0-FF

; ============================================================================
; parity_tbl — Parity of byte (1=even parity, 0=odd parity)
; ============================================================================
; 8086 PF = 1 if low byte of result has even number of 1-bits
parity_tbl:
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0
        .byte   1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1