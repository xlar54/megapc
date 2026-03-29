; ============================================================================
; int.asm — Interrupt Handling & Stack Operations
; ============================================================================
;
; Stack operations use SS:SP for push/pop.
; SS base is pre-computed in ss_base for fast access.
;
; INT pushes FLAGS, CS, IP then jumps to IVT[n].
; IVT is at 8086 linear $00000 (bank 4 $40000), 256 entries × 4 bytes.

STACK_TEMP      = $8FE8         ; 2 bytes: temp buffer for attic stack DMA

; ============================================================================
; push_word — Push 16-bit value onto 8086 stack
; ============================================================================
; Input: op_result+0/+1 = word to push
; Modifies: SP, writes to SS:SP
;
push_word:
        ; Decrement SP by 2
        sec
        lda reg_sp86
        sbc #2
        sta reg_sp86
        lda reg_sp86+1
        sbc #0
        sta reg_sp86+1

        ; Write word to SS:SP using cache path
        lda reg_sp86
        sta temp32
        lda reg_sp86+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3

        lda seg_override_en     ; Save & disable override — stack always uses SS
        pha
        lda #0
        sta seg_override_en

        ldx #SEG_SS_OFS
        jsr seg_ofs_to_linear

        pla
        sta seg_override_en     ; Restore override

        jsr linear_to_chip

        lda op_result
        ldz #0
        sta [temp_ptr],z

        ; Check if high byte crosses cache page boundary
        lda temp32
        cmp #$FF
        beq _pushw_cross

        ; Same page: write high byte directly
        lda op_result+1
        ldz #1
        sta [temp_ptr],z
        ; Mark cache dirty if write went to cache buffer (bank 0)
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       rts

_pushw_cross:
        ; Mark first page dirty if in cache
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+
        ; Page boundary: increment linear address and re-resolve
        inc temp32+1
        bne +
        inc temp32+2
+       jsr linear_to_chip
        lda op_result+1
        ldz #0
        sta [temp_ptr],z
        ; Mark second page dirty if in cache
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       rts

; ============================================================================
; pop_word — Pop 16-bit value from 8086 stack
; ============================================================================
; Output: op_result+0/+1 = popped word
; Modifies: SP
;
pop_word:
        ; Read word from SS:SP using cache path
        lda reg_sp86
        sta temp32
        lda reg_sp86+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3

        lda seg_override_en     ; Save & disable override — stack always uses SS
        pha
        lda #0
        sta seg_override_en

        ldx #SEG_SS_OFS
        jsr seg_ofs_to_linear

        pla
        sta seg_override_en     ; Restore override

        jsr linear_to_chip

        ldz #0
        lda [temp_ptr],z
        sta op_result

        ; Check if high byte crosses cache page boundary
        lda temp32
        cmp #$FF
        beq _popw_cross

        ; Same page: read high byte directly
        ldz #1
        lda [temp_ptr],z
        sta op_result+1
        bra _popw_sp

_popw_cross:
        ; Page boundary: increment linear address and re-resolve
        inc temp32+1
        bne +
        inc temp32+2
+       jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_result+1

_popw_sp:
        ; Increment SP by 2
        clc
        lda reg_sp86
        adc #2
        sta reg_sp86
        lda reg_sp86+1
        adc #0
        sta reg_sp86+1
        rts

; ============================================================================
; do_sw_interrupt — Execute software interrupt
; ============================================================================
; Input: A = interrupt number (0–255)
; Pushes FLAGS, CS, IP then loads new CS:IP from IVT.
;
do_sw_interrupt:

        pha                     ; Save int number

        ; Push FLAGS
        jsr flags_to_word
        jsr push_word

        ; Clear IF and TF
        lda #0
        sta flag_if
        sta flag_tf

        ; Push CS
        lda reg_cs
        sta op_result
        lda reg_cs+1
        sta op_result+1
        jsr push_word

        ; Push IP (current = return address)
        lda reg_ip
        sta op_result
        lda reg_ip+1
        sta op_result+1
        jsr push_word

        ; Load new CS:IP from IVT
        ; IVT entry = int_num × 4 at linear address $00000
        ; = bank 4 address $40000 + (int_num × 4)
        pla                     ; Recover int number
        ; Multiply by 4
        sta scratch_a
        lda #0
        sta scratch_b
        asl scratch_a
        rol scratch_b
        asl scratch_a
        rol scratch_b           ; scratch_a/b = int_num × 4

        ; Read 4 bytes from IVT: IP_lo, IP_hi, CS_lo, CS_hi
        clc
        lda #$00
        adc scratch_a
        sta temp_ptr
        lda #$00
        adc scratch_b
        sta temp_ptr+1
        lda #$04                ; Bank 4
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldz #0
        lda [temp_ptr],z
        sta reg_ip
        ldz #1
        lda [temp_ptr],z
        sta reg_ip+1
        ldz #2
        lda [temp_ptr],z
        sta reg_cs
        ldz #3
        lda [temp_ptr],z
        sta reg_cs+1

        ; Mark CS dirty and recompute
        lda #1
        sta cs_dirty
        jsr compute_cs_base
        jsr update_opcode_ptr
        rts

; ============================================================================
; check_hw_interrupts — Check for and service hardware interrupts
; ============================================================================
; Called from main loop. Checks int8_asap and IF.
; INT 8 (timer) is the primary hardware interrupt.
;
check_hw_interrupts:
        lda int8_asap
        beq _chi_done
        lda flag_if
        beq _chi_done
        lda #0
        sta int8_asap
        lda #8
        jsr do_sw_interrupt
_chi_done:
        rts