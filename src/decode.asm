; ============================================================================
; decode.asm — Main Loop, Instruction Fetch & Decode
; ============================================================================
;
; Main emulation loop:
;   1. Check for pending interrupts
;   2. Fetch opcode byte at CS:IP
;   3. Look up decode tables (xlat, extra_field, i_w, i_d, etc.)
;   4. Fetch ModR/M if needed
;   5. Fetch immediates if needed
;   6. Dispatch to handler via jump table
;
; The decode tables live in bank 1 at TBL_BASE ($12000).
; We access them via [temp_ptr2],z with temp_ptr2 set to table base.

; ============================================================================
; read_tbl — Read byte from decode table
; ============================================================================
; Input:  temp_ptr2 = 32-bit base of table
;         Z = index (raw_opcode)
; Output: A = table value
;
; Helper macro to set temp_ptr2 to a table address
set_tbl .macro addr
        lda #<\addr
        sta temp_ptr2
        lda #>\addr
        sta temp_ptr2+1
        lda #(\addr >> 16)
        sta temp_ptr2+2
        lda #$00
        sta temp_ptr2+3
        .endm

; ============================================================================
; Main Emulation Loop
; ============================================================================
main_loop:
        ; --- Recompute segment bases if dirty ---
        jsr compute_cs_base
        jsr compute_ss_base
        jsr compute_ds_base

ml_next:
        ; --- Save previous raw_opcode to fixed RAM ---
        lda raw_opcode
        sta $8F00

        ; Trap CS in CGA range ($B000-$BFFF)
        lda reg_cs+1
        cmp #$B0
        bcc _ml_cs_ok
        cmp #$C0
        bcs _ml_cs_ok
        ; Bad CS in CGA range! Save state and halt
        lda reg_cs
        sta $8FC0
        lda reg_cs+1
        sta $8FC1
        lda reg_ip
        sta $8FC2
        lda reg_ip+1
        sta $8FC3
        lda $8F00               ; prev opcode
        sta $8FC4
        lda reg_sp86
        sta $8FC5
        lda reg_sp86+1
        sta $8FC6
        lda reg_ss
        sta $8FC7
        lda reg_ss+1
        sta $8FC8
        lda reg_ds
        sta $8FC9
        lda reg_ds+1
        sta $8FCA
        lda reg_es
        sta $8FCB
        lda reg_es+1
        sta $8FCC
        jmp *                   ; Halt silently
_ml_cs_ok:

        ; --- Timer tick (INT 8 emulation) ---
        ; Every ~1024 instructions: increment BDA timer counter and
        ; deliver INT 8 only if FreeDOS has hooked it (IVT[8] != F000:FF00)
        inc tick_counter
        bne _ml_no_tick
        inc tick_counter+1
        lda tick_counter+1
        and #$03
        bne _ml_no_tick

        ; Increment 32-bit BDA tick counter at $0040:006C (bank 4 $4046C)
        lda #$6C
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04                ; Bank 4
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
        bcc +
        ldz #2
        lda [temp_ptr],z
        adc #0
        sta [temp_ptr],z
        bcc +
        ldz #3
        lda [temp_ptr],z
        adc #0
        sta [temp_ptr],z
+
_ml_no_tick:

        ; --- Code cache check (for attic-backed CS segments) ---
        lda cs_in_attic
        beq _ml_normal_ptr

        ; CS is in attic — check if the right page is cached
        clc
        lda cs_base_linear
        adc reg_ip
        ; byte 0 not needed for page check
        lda cs_base_linear+1
        adc reg_ip+1
        cmp code_cache_pg_lo
        bne _ml_code_miss
        lda cs_base_linear+2
        adc #0
        cmp code_cache_pg_hi
        beq _ml_code_hit

_ml_code_miss:
        ; Flush data cache before loading code from attic
        ; (Required: data cache may have dirty pages for this attic region
        ;  that haven't been written back yet, e.g. from REP MOVSW boot copy)
        jsr cache_flush_all

        ; Compute full linear address of current CS:IP
        clc
        lda cs_base_linear
        adc reg_ip
        sta temp32              ; byte 0 (offset within page)
        lda cs_base_linear+1
        adc reg_ip+1
        sta temp32+1            ; page lo
        sta code_cache_pg_lo
        lda cs_base_linear+2
        adc #0
        and #$0F                ; Mask to 20 bits (prevent floppy attic overlap)
        sta temp32+2            ; page hi
        sta code_cache_pg_hi

        ; DMA 256 bytes from attic to CODE_CACHE_BUF
        lda temp32+2
        sta _dma_ccache_src_bank
        lda temp32+1
        sta _dma_ccache_src+1
        lda #$00
        sta _dma_ccache_src

        lda #$00
        sta $D707
        .byte $80, $80          ; src MB = $80 (attic)
        .byte $81, $00          ; dst MB = $00 (chip)
        .byte $00               ; end options
        .byte $00               ; copy
        .word $0100             ; 256 bytes
_dma_ccache_src:
        .word $0000             ; src addr (patched)
_dma_ccache_src_bank:
        .byte $00               ; src bank (patched)
        .word CODE_CACHE_BUF    ; dst addr
        .byte $00               ; dst bank
        .byte $00
        .word $0000

        ; Also load 8 bytes from NEXT page for instruction spillover
        clc
        lda temp32+1
        adc #1
        sta _dma_ccache_spill_src+1
        lda temp32+2
        adc #0
        sta _dma_ccache_spill_bank

        lda #$00
        sta _dma_ccache_spill_src
        lda #$00
        sta $D707
        .byte $80, $80          ; src MB = $80 (attic)
        .byte $81, $00          ; dst MB = $00 (chip)
        .byte $00               ; end options
        .byte $00               ; copy
        .word $0008             ; 8 bytes
_dma_ccache_spill_src:
        .word $0000             ; src addr (patched)
_dma_ccache_spill_bank:
        .byte $00               ; src bank (patched)
        .word CODE_CACHE_SPILL  ; dst addr = spillover area
        .byte $00               ; dst bank
        .byte $00
        .word $0000

_ml_code_hit:
        ; Set opcode_ptr to CODE_CACHE_BUF + (low byte of linear addr)
        clc
        lda cs_base_linear
        adc reg_ip
        ; A = offset within 256-byte page
        clc
        adc #<CODE_CACHE_BUF    ; = $00
        sta opcode_ptr
        lda #>CODE_CACHE_BUF    ; = $90
        adc #0
        sta opcode_ptr+1
        lda #$00
        sta opcode_ptr+2
        sta opcode_ptr+3
        bra _ml_ptr_done

_ml_normal_ptr:
        ; --- Normal: update opcode_ptr from cs_base + IP ---
        jsr update_opcode_ptr

_ml_ptr_done:

        ; --- Increment instruction counter ---
        inc inst_counter
        bne _ml_no_debug
        inc inst_counter+1
        ; --- Debug: disabled ---
_ml_no_debug:

        ; --- Save IP for REP ---
        lda reg_ip
        sta decode_ip_start
        lda reg_ip+1
        sta decode_ip_start+1

        ; --- Fetch opcode byte ---
        jsr fetch_byte
        sta raw_opcode

        ; --- Handle prefix bytes ---
        ; Segment overrides: 26=ES, 2E=CS, 36=SS, 3E=DS
        cmp #$26
        beq _ml_seg_es
        cmp #$2E
        beq _ml_seg_cs
        cmp #$36
        beq _ml_seg_ss
        cmp #$3E
        beq _ml_seg_ds
        ; REP prefixes: F2=REPNZ, F3=REPZ
        cmp #$F2
        beq _ml_rep_nz
        cmp #$F3
        beq _ml_rep_z
        ; LOCK prefix: F0 — treat as NOP
        cmp #$F0
        beq ml_next
        bra _ml_decode

_ml_seg_es:
        lda #1
        sta seg_override_en
        lda #SEG_ES_OFS
        sta seg_override
        bra ml_next            ; Fetch next byte (the actual opcode)
_ml_seg_cs:
        lda #1
        sta seg_override_en
        lda #SEG_CS_OFS
        sta seg_override
        bra ml_next
_ml_seg_ss:
        lda #1
        sta seg_override_en
        lda #SEG_SS_OFS
        sta seg_override
        bra ml_next
_ml_seg_ds:
        lda #1
        sta seg_override_en
        lda #SEG_DS_OFS
        sta seg_override
        bra ml_next

_ml_rep_nz:
        lda #1
        sta rep_override_en
        lda #1                  ; REPNZ mode
        sta rep_mode
        bra ml_next
_ml_rep_z:
        lda #1
        sta rep_override_en
        lda #0                  ; REPZ mode
        sta rep_mode
        bra ml_next

; --- Decode the opcode ---
_ml_decode:
        ; Look up all decode tables in code segment using raw_opcode as X index
        ldx raw_opcode

        ; xlat_opcode = opcode_dispatch[raw_opcode]
        lda opcode_dispatch,x
        sta xlat_opcode

        ; extra_field = extra_field_tbl[raw_opcode]
        lda extra_field_tbl,x
        sta extra_field

        ; set_flags_type = set_flags_tbl[raw_opcode]
        lda set_flags_tbl,x
        sta set_flags_type

        ; i_w = i_w_tbl[raw_opcode]
        lda i_w_tbl,x
        sta i_w

        ; i_d = i_d_tbl[raw_opcode]
        lda i_d_tbl,x
        sta i_d

        ; i_mod_sz = i_mod_sz_tbl[raw_opcode]
        lda i_mod_sz_tbl,x
        sta i_mod_sz

        ; --- Decode ModR/M if needed ---
        lda i_mod_sz
        beq _ml_no_modrm
        jsr decode_modrm
_ml_no_modrm:

        ; --- Fetch immediate data if needed ---
        ; base_size = TBL_BASE_SIZE[raw_opcode]
        ; If base_size > 0, fetch that many additional bytes as i_data0
        ; (This is simplified; full version checks i_w for word immediates)
        ; For now, the individual opcode handlers fetch their own immediates

        ; --- Reset advance_ip (handlers that jump set this to 0) ---
        lda #1
        sta advance_ip

        ; --- REP with CX=0: skip string op entirely ---
        ; On real 8086, REP with CX=0 performs zero iterations
        lda rep_override_en
        beq _ml_no_rep_skip
        ; Check if this is a string op (A4-AF)
        lda raw_opcode
        cmp #$A4
        bcc _ml_no_rep_skip
        cmp #$B0
        bcs _ml_no_rep_skip
        ; It's a REP string op — check CX
        lda reg_cx
        ora reg_cx+1
        bne _ml_no_rep_skip
        ; CX=0: skip execution, clear REP
        lda #0
        sta rep_override_en
        sta seg_override_en
        jmp opcode_done
_ml_no_rep_skip:

        ; --- Dispatch to handler ---
        lda xlat_opcode
        asl                     ; ×2 for 16-bit jump table entries
        tax
        jmp (opcode_jump_tbl,x)

; ============================================================================
; opcode_done — Return point after each instruction
; ============================================================================
opcode_done:
        ; --- REP prefix handling ---
        ; If a REP prefix was active, check if we need to repeat
        lda rep_override_en
        beq _od_no_rep

        ; REP applies to string ops: A4-A7, AA-AF
        ; Check if the just-executed opcode was a string op
        lda raw_opcode
        cmp #$A4
        bcc _od_clear_rep
        cmp #$B0
        bcs _od_clear_rep

        ; Decrement CX
        sec
        lda reg_cx
        sbc #1
        sta reg_cx
        lda reg_cx+1
        sbc #0
        sta reg_cx+1

        ; If CX=0, stop repeating
        lda reg_cx
        ora reg_cx+1
        beq _od_clear_rep

        ; For REPZ/REPNZ with CMPS/SCAS, check ZF
        lda raw_opcode
        cmp #$A6               ; CMPSB
        beq _od_rep_check_zf
        cmp #$A7               ; CMPSW
        beq _od_rep_check_zf
        cmp #$AE               ; SCASB
        beq _od_rep_check_zf
        cmp #$AF               ; SCASW
        beq _od_rep_check_zf
        ; MOVS/STOS/LODS: just repeat (no ZF check)
        bra _od_rep_again

_od_rep_check_zf:
        lda rep_mode
        beq _od_repz            ; rep_mode=0 → REPZ
        ; REPNZ: repeat while ZF=0
        lda flag_zf
        bne _od_clear_rep       ; ZF=1 → stop
        bra _od_rep_again
_od_repz:
        ; REPZ: repeat while ZF=1
        lda flag_zf
        beq _od_clear_rep       ; ZF=0 → stop

_od_rep_again:
        ; Rewind IP to re-execute the string op
        lda decode_ip_start
        sta reg_ip
        lda decode_ip_start+1
        sta reg_ip+1
        jsr update_opcode_ptr
        ; Don't clear rep_override — it persists
        jmp ml_next

_od_clear_rep:
        lda #0
        sta rep_override_en

_od_no_rep:
        ; Clear segment override for next instruction
        lda #0
        sta seg_override_en

        ; Check for trap flag
        lda flag_tf
        beq +
        lda #1
        jsr do_sw_interrupt     ; INT 1 (single step)
        jsr compute_cs_base
+
        ; Continue main loop
        jmp ml_next

; ============================================================================
; Opcode Jump Table
; ============================================================================
; Handler indices 0–49 (decimal). Each entry is 2-byte address.
; Unimplemented opcodes dispatch to op_nop_unimpl.
;
opcode_jump_tbl:
        .word op_cond_jump      ; $00 — Jcc (70–7F)
        .word op_mov_reg_imm    ; $01 — MOV reg, imm (B0–BF)
        .word op_inc_dec_r16    ; $02 — INC/DEC r16 (40–4F)
        .word op_push_r16       ; $03 — PUSH r16 (50–57)
        .word op_pop_r16        ; $04 — POP r16 (58–5F)
        .word op_inc_dec_rm     ; $05 — INC/DEC r/m (FE/FF)
        .word op_grp_f6f7      ; $06 — GRP F6/F7 (TEST/NOT/NEG/MUL/DIV)
        .word op_alu_imm_acc   ; $07 — ALU acc, imm (04/05/0C/0D/etc.)
        .word op_alu_imm_rm    ; $08 — ALU r/m, imm (80–83)
        .word op_alu_reg_rm    ; $09 — ALU reg, r/m (00–03/08–0B/etc.)
        .word op_mov_sreg      ; $0A — MOV sreg (8C/8E)
        .word op_mov_acc_mem   ; $0B — MOV acc, mem (A0–A3)
        .word op_shift_rot     ; $0C — Shift/Rotate (C0/C1/D0–D3)
        .word op_loop          ; $0D — LOOP/LOOPZ/LOOPNZ/JCXZ (E0–E3)
        .word op_jmp_call      ; $0E — JMP/CALL near (E8/E9/EA/EB)
        .word op_test_rm       ; $0F — TEST r/m,reg (84/85)
        .word op_xchg_ax       ; $10 — XCHG AX,r16 (90–97)
        .word op_movs_stos     ; $11 — MOVS/STOS (A4/A5/AA/AB)
        .word op_cmps_scas     ; $12 — CMPS/SCAS (A6/A7/AE/AF)
        .word op_ret           ; $13 — RET/RETF/IRET (C2/C3/CA/CB/CF)
        .word op_mov_rm_imm    ; $14 — MOV r/m, imm (C6/C7)
        .word op_in            ; $15 — IN (E4/E5/EC/ED)
        .word op_out           ; $16 — OUT (E6/E7/EE/EF)
        .word op_rep           ; $17 — REP (F2/F3)
        .word op_xchg_rm       ; $18 — XCHG r/m,reg (86/87)
        .word op_push_seg      ; $19 — PUSH seg (06/0E/16/1E)
        .word op_pop_seg       ; $1A — POP seg (07/17/1F)
        .word op_seg_override  ; $1B — Segment override (26/2E/36/3E) — handled in prefix
        .word op_daa_das       ; $1C — DAA/DAS (27/2F)
        .word op_aaa_aas       ; $1D — AAA/AAS (37/3F)
        .word op_cbw           ; $1E — CBW (98)
        .word op_cwd           ; $1F — CWD (99)
        .word op_call_far      ; $20 — CALL far (9A)
        .word op_pushf         ; $21 — PUSHF (9C)
        .word op_popf          ; $22 — POPF (9D)
        .word op_sahf          ; $23 — SAHF (9E)
        .word op_lahf          ; $24 — LAHF (9F)
        .word op_les_lds       ; $25 — LES/LDS (C4/C5)
        .word op_int3          ; $26 — INT 3 (CC)
        .word op_int_imm       ; $27 — INT imm (CD)
        .word op_into          ; $28 — INTO (CE)
        .word op_aam           ; $29 — AAM (D4)
        .word op_aad           ; $2A — AAD (D5)
        .word op_salc          ; $2B — SALC (D6)
        .word op_xlat          ; $2C — XLAT (D7)
        .word op_cmc           ; $2D — CMC (F5)
        .word op_clc_stc_etc   ; $2E — CLC/STC/CLI/STI/CLD/STD (F8–FD)
        .word op_test_acc_imm  ; $2F — TEST acc, imm (A8/A9)
        .word op_emu_special   ; $30 — Emulator special (0F prefix)
        .word op_nop_unimpl    ; $31 — NOP / unimplemented
        .word op_mov_reg_rm    ; $32 — MOV reg,r/m (88–8B)
        .word op_lea           ; $33 — LEA (8D)
        .word op_int_ret       ; $34 — IRET (CF) — separate from RET
        ; Pad to 50 entries for safety
        .word op_pusha          ; $35 — PUSHA (60)
        .word op_popa           ; $36 — POPA (61)
        .word op_push_imm16     ; $37 — PUSH imm16 (68)
        .word op_push_imm8      ; $38 — PUSH imm8 (6A)
        .word op_hlt            ; $39 — HLT (F4)
        .word op_nop_unimpl    ; $39
        .word op_nop_unimpl    ; $3A

; ============================================================================
; Debug: print A as 2 hex digits via CHROUT
; ============================================================================
debug_print_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr _dph_nib
        pla
        and #$0F
_dph_nib:
        cmp #$0A
        bcc +
        adc #$06               ; adjust for A-F (carry is set from cmp)
+       adc #$30               ; '0'
        jmp CHROUT