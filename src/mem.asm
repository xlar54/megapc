; ============================================================================
; mem.asm — Memory Access API
; ============================================================================
;
; Clean API for all 8086 memory access. Every read/write goes through here.
;
; The 8086 has a 20-bit address space (1MB). We map it as:
;   $00000–$0FFFF → Bank 4 chip RAM (fast [ptr],z)
;   $10000–$EFFFF → Attic RAM via DMA cache (see cache.asm)
;   $F0000–$FFFFF → Bank 5 chip RAM (fast [ptr],z)
;
; API functions:
;   seg_ofs_to_linear  — Convert segment:offset to 20-bit linear address
;   linear_to_chip     — Map 20-bit linear to 32-bit chip/cache address
;   mem_read8          — Read byte from seg:ofs (segment reg offset in X)
;   mem_write8         — Write byte A to seg:ofs (segment reg offset in X)
;   mem_read16         — Read word from seg:ofs
;   mem_write16        — Write word from op_result to seg:ofs
;   fetch_byte         — Fetch next byte at CS:IP and advance IP
;   fetch_word         — Fetch next word at CS:IP and advance IP
;
; Segment override: if seg_override_en != 0, use seg_override instead of
;                   the default segment register.

; ============================================================================
; seg_ofs_to_linear — Segment:Offset → 20-bit linear in temp32
; ============================================================================
; Input:  X = offset from regs base to segment register (e.g., SEG_DS_OFS)
;         temp32+0/+1 = 16-bit offset
; Output: temp32+0..+2 = 20-bit linear address (temp32+3 cleared)
;
; Linear = (Segment << 4) + Offset
;
seg_ofs_to_linear:
        ; Check for segment override
        lda seg_override_en
        beq +
        ldx seg_override        ; Use override segment instead
+
        ; Shift segment left 4 bits and add offset
        ; seg_lo is at regs,x  seg_hi is at regs+1,x
        lda regs,x             ; seg_lo
        asl                     ; ×2
        asl                     ; ×4
        asl                     ; ×8
        asl                     ; ×16 — low nibble of seg_lo goes to temp
        sta scratch_a           ; seg_lo << 4 (bits 4–7 of seg_lo → bits 0–3)
        lda regs,x
        lsr                     ; recover bits 4–7 of seg_lo → becomes bits 8–11
        lsr
        lsr
        lsr
        sta scratch_b           ; high nibble of seg_lo shifted down

        lda regs+1,x           ; seg_hi
        asl
        asl
        asl
        asl                     ; seg_hi << 4
        ora scratch_b           ; combine with high nibble of seg_lo
        sta scratch_b           ; = byte 1 of (segment << 4)

        lda regs+1,x           ; seg_hi again
        lsr
        lsr
        lsr
        lsr                     ; seg_hi >> 4 = bits 16–19
        sta scratch_c           ; = byte 2 of (segment << 4)

        ; Now add offset (temp32+0..+1) to segment base (scratch_a/b/c)
        clc
        lda temp32
        adc scratch_a
        sta temp32
        lda temp32+1
        adc scratch_b
        sta temp32+1
        lda #0
        adc scratch_c
        and #$0F                ; Mask to 20 bits
        sta temp32+2
        lda #$00
        sta temp32+3            ; Clear byte 3 (NOT stz — doesn't work on MEGA65)
        rts

; ============================================================================
; linear_to_chip — Map 20-bit linear → 32-bit chip address in temp_ptr
; ============================================================================
; Input:  temp32+0..+2 = 20-bit linear address
; Output: temp_ptr+0..+3 = 32-bit chip/cache address for [ptr],z
;         (For attic addresses, returns pointer into cache buffer)
;
linear_to_chip:
        lda temp32+2
        cmp #$0F
        bcs _ltc_f_seg
        cmp #$0B
        bne _ltc_not_b
        ; Check if $B8000-$BFFFF (CGA) or $B0000-$B7FFF (MDA/other)
        lda temp32+1
        cmp #$80
        bcs _ltc_cga            ; $B8xxx+ → CGA buffer
        bra _ltc_attic          ; $B0xxx-$B7xxx → attic
_ltc_not_b:
        cmp #$01
        bcs _ltc_attic          ; $10000-$EFFFF → attic DMA

        ; --- $00000–$0FFFF: Bank 4 direct ---
        lda temp32
        sta temp_ptr
        lda temp32+1
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        rts

_ltc_cga:
        ; --- $B8000–$BFFFF: Map to bank 2 at $2A000 ---
        lda temp32
        sta temp_ptr
        lda temp32+1
        clc
        adc #$20
        sta temp_ptr+1
        lda #$02
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        rts

_ltc_f_seg:
        ; --- $F0000–$FFFFF: Bank 5 direct ---
        lda temp32
        sta temp_ptr
        lda temp32+1
        sta temp_ptr+1
        lda #$05
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        rts

_ltc_attic:
        ; --- $10000–$EFFFF: Attic via cache ---
        ; Page = temp32+2 : temp32+1 (high byte + mid byte)
        ; Offset = temp32+0
        jsr cache_access        ; Returns pointer in temp_ptr
        rts

; ============================================================================
; mark_cache_dirty — Mark the correct cache line as dirty
; ============================================================================
; Derives line index from temp_ptr+1 (high byte of cache buffer pointer).
; CACHE_BUF is page-aligned, so line = temp_ptr+1 - >CACHE_BUF.
; Must only be called when temp_ptr+2 == 0 (confirmed in cache buffer).
;
mark_cache_dirty:
        lda temp_ptr+1
        sec
        sbc #>CACHE_BUF
        tax
        lda #1
        sta cache_dirty,x
        jsr invalidate_code_cache_for_line
        rts

; ============================================================================
; mem_read8 — Read byte from segment:offset
; ============================================================================
; Input:  X = segment register offset (SEG_DS_OFS etc.)
;         temp32+0/+1 = 16-bit offset
; Output: A = byte read
;
mem_read8:
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        rts

; ============================================================================
; mem_write8 — Write byte to segment:offset
; ============================================================================
; Input:  X = segment register offset
;         temp32+0/+1 = 16-bit offset
;         A = byte to write (saved in scratch_d before call)
; Note: Caller should store value in scratch_d before calling, since
;       seg_ofs_to_linear trashes A.
;
mem_write8:
        jsr seg_ofs_to_linear
        ; Write-protect F-segment (BIOS ROM)
        lda temp32+2
        cmp #$0F
        bcs _mw8_rom            ; $F0000+ = ROM, discard write
        jsr linear_to_chip
        lda scratch_d
        ldz #0
        sta [temp_ptr],z
        ; Mark cache dirty if we wrote to cache buffer (bank 0)
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       rts
_mw8_rom:
        rts                     ; Silently discard ROM write

; ============================================================================
; mem_read16 — Read 16-bit word from segment:offset
; ============================================================================
; Input:  X = segment register offset
;         temp32+0/+1 = 16-bit offset
; Output: op_source+0/+1 = 16-bit word (little-endian)
;
mem_read16:
        ; Save original offset for segment wrap detection
        lda temp32
        sta $8F60
        lda temp32+1
        sta $8F61
        stx $8F62               ; Save segment register offset

        jsr seg_ofs_to_linear
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_source

        ; Check for segment wrap (offset was $FFFF)
        lda $8F60
        and $8F61
        cmp #$FF
        beq _mr16_seg_wrap

        ; Check page boundary crossing (linear low byte = $FF)
        lda temp32
        cmp #$FF
        beq _mr16_cross
        ldz #1
        lda [temp_ptr],z
        sta op_source+1
        rts
_mr16_cross:
        inc temp32+1
        bne +
        inc temp32+2
+       jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_source+1
        rts
_mr16_seg_wrap:
        ; Offset was $FFFF — wrap to $0000 in same segment
        lda #0
        sta temp32
        sta temp32+1
        ldx $8F62               ; Restore segment
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        sta op_source+1
        rts

; ============================================================================
; mem_write16 — Write 16-bit word to segment:offset
; ============================================================================
; Input:  X = segment register offset
;         temp32+0/+1 = 16-bit offset
;         op_result+0/+1 = 16-bit word to write
;
mem_write16:
        ; Save original offset for segment wrap detection
        lda temp32
        sta $8F60
        lda temp32+1
        sta $8F61
        stx $8F62               ; Save segment register offset

        jsr seg_ofs_to_linear
        ; Write-protect F-segment (BIOS ROM)
        lda temp32+2
        cmp #$0F
        bcs _mw16_rom
        jsr linear_to_chip
        lda op_result
        ldz #0
        sta [temp_ptr],z
        ; Mark cache dirty if in cache buffer
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+
        ; Check for segment wrap (offset was $FFFF)
        lda $8F60
        and $8F61
        cmp #$FF
        beq _mw16_seg_wrap

        ; Check page boundary crossing
        lda temp32
        cmp #$FF
        beq _mw16_cross
        lda op_result+1
        ldz #1
        sta [temp_ptr],z
        rts
_mw16_cross:
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
+       rts
_mw16_seg_wrap:
        ; Offset was $FFFF — wrap to $0000 in same segment
        lda #0
        sta temp32
        sta temp32+1
        ldx $8F62               ; Restore segment
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        lda op_result+1
        ldz #0
        sta [temp_ptr],z
        ; Mark cache dirty
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+       rts
_mw16_rom:
        rts                     ; Silently discard ROM write

; ============================================================================
; Instruction Fetch Helpers
; ============================================================================
; These use the pre-computed cs_base for speed.
; CS:IP → opcode_ptr is kept up-to-date.

; update_opcode_ptr — Recompute opcode_ptr = cs_base + IP
; Called when CS or IP changes.
update_opcode_ptr:
        clc
        lda cs_base
        adc reg_ip
        sta opcode_ptr
        lda cs_base+1
        adc reg_ip+1
        sta opcode_ptr+1
        lda cs_base+2
        adc #0
        ; A20 wrap: if bank > $05 (past F-segment), wrap to bank 4
        cmp #$06
        bcc +
        ; Wrapped past 1MB — map to bank 4 (segment 0)
        lda #$04
+       sta opcode_ptr+2
        lda #$00
        sta opcode_ptr+3        ; NOT stz
        rts

; fetch_byte — Read byte at CS:IP, advance IP by 1
; Output: A = fetched byte
fetch_byte:
        ldz #0
        lda [opcode_ptr],z
        inc reg_ip
        bne _fb_no_wrap
        inc reg_ip+1
        beq _fb_ip_wrapped      ; IP wrapped $FFFF→$0000: recompute opcode_ptr
_fb_no_wrap:
        ; Fast path: just increment opcode_ptr
        inc opcode_ptr
        bne +
        inc opcode_ptr+1
        bne +
        inc opcode_ptr+2
        ; A20 wrap check
        lda opcode_ptr+2
        cmp #$06
        bcc +
        lda #$04
        sta opcode_ptr+2
+       rts

_fb_ip_wrapped:
        ; IP crossed segment boundary — must recompute opcode_ptr from cs_base + 0
        pha
        jsr update_opcode_ptr
        pla
        rts

; fetch_word — Read word at CS:IP, advance IP by 2
; Output: A = low byte, scratch_a = high byte
;         (Also stored in i_data0 by most callers)
fetch_word:
        ldz #0
        lda [opcode_ptr],z
        pha
        ldz #1
        lda [opcode_ptr],z
        sta scratch_a

        ; Advance IP by 2
        clc
        lda reg_ip
        adc #2
        sta reg_ip
        lda reg_ip+1
        adc #0
        sta reg_ip+1
        bcs _fw_ip_wrapped      ; Carry = IP crossed $FFFF

        ; Advance opcode_ptr by 2
        clc
        lda opcode_ptr
        adc #2
        sta opcode_ptr
        lda opcode_ptr+1
        adc #0
        sta opcode_ptr+1
        bcc +
        inc opcode_ptr+2
        ; A20 wrap check (same as fetch_byte)
        lda opcode_ptr+2
        cmp #$06
        bcc +
        lda #$04
        sta opcode_ptr+2
+
        pla                     ; A = low byte
        rts

_fw_ip_wrapped:
        ; IP crossed segment boundary — recompute opcode_ptr
        jsr update_opcode_ptr
        pla                     ; A = low byte
        rts

; ============================================================================
; Segment Base Computation
; ============================================================================
; Compute chip RAM base address for a segment register.
; Result is (segment << 4) mapped to chip bank.
;
; compute_cs_base / compute_ss_base / compute_ds_base
; These cache the result and only recompute when dirty flag is set.

compute_cs_base:
        lda cs_dirty
        beq _ccb_done
        ; First compute the raw 20-bit linear CS base (before chip mapping)
        ldx #SEG_CS_OFS
        ; Inline seg << 4 to get the unmapped 20-bit address
        lda regs,x
        asl
        asl
        asl
        asl
        sta cs_base_linear
        lda regs,x
        lsr
        lsr
        lsr
        lsr
        sta cs_base_linear+1
        lda regs+1,x
        asl
        asl
        asl
        asl
        ora cs_base_linear+1
        sta cs_base_linear+1
        lda regs+1,x
        lsr
        lsr
        lsr
        lsr
        sta cs_base_linear+2
        lda #$00
        sta cs_base_linear+3

        ; Now check which range CS falls into
        lda cs_base_linear+2
        cmp #$0F
        bcs _ccb_f_seg
        cmp #$01
        bcs _ccb_attic

        ; $0xxxx → bank 4 direct
        lda cs_base_linear
        sta cs_base
        lda cs_base_linear+1
        sta cs_base+1
        lda #$04
        sta cs_base+2
        lda #$00
        sta cs_base+3
        sta cs_in_attic
        lda #0
        sta cs_dirty
        jsr update_opcode_ptr
        rts

_ccb_f_seg:
        ; $Fxxxx → bank 5 direct
        lda cs_base_linear
        sta cs_base
        lda cs_base_linear+1
        sta cs_base+1
        lda #$05
        sta cs_base+2
        lda #$00
        sta cs_base+3
        sta cs_in_attic
        lda #0
        sta cs_dirty
        jsr update_opcode_ptr
        rts

_ccb_attic:
        ; $1xxxx–$Exxxx → attic, use code cache
        lda #$01
        sta cs_in_attic
        ; cs_base is not meaningful for direct chip access, but set it
        ; to something that won't crash. The main loop will override
        ; opcode_ptr from the code cache.
        lda cs_base_linear
        sta cs_base
        lda cs_base_linear+1
        sta cs_base+1
        lda #$04                ; placeholder bank
        sta cs_base+2
        lda #$00
        sta cs_base+3
        sta cs_dirty
        ; Don't call update_opcode_ptr — main loop handles it via code cache
_ccb_done:
        rts

compute_ss_base:
        lda ss_dirty
        beq _csb_done
        ldx #SEG_SS_OFS
        jsr compute_seg_base
        lda temp32
        sta ss_base
        lda temp32+1
        sta ss_base+1
        lda temp32+2
        sta ss_base+2
        lda temp32+3
        sta ss_base+3
        lda #0
        sta ss_dirty
_csb_done:
        rts

compute_ds_base:
        lda ds_dirty
        beq _cdb_done
        ldx #SEG_DS_OFS
        jsr compute_seg_base
        lda temp32
        sta ds_base
        lda temp32+1
        sta ds_base+1
        lda temp32+2
        sta ds_base+2
        lda temp32+3
        sta ds_base+3
        lda #0
        sta ds_dirty
_cdb_done:
        rts

; compute_seg_base — Compute (segment << 4) and map to chip address
; Input:  X = segment register offset from regs
; Output: temp32 = 32-bit chip address
compute_seg_base:
        ; Segment << 4
        lda regs,x
        asl
        asl
        asl
        asl
        sta temp32              ; Low byte of (seg << 4)
        lda regs,x
        lsr
        lsr
        lsr
        lsr
        sta temp32+1
        lda regs+1,x
        asl
        asl
        asl
        asl
        ora temp32+1
        sta temp32+1            ; Mid byte
        lda regs+1,x
        lsr
        lsr
        lsr
        lsr
        sta temp32+2            ; High nibble (bits 16–19)
        lda #$00
        sta temp32+3

        ; Now map linear base to chip address
        ; We only need the bank byte — offset stays as-is
        lda temp32+2
        cmp #$0F
        bcs _csb_f_seg
        cmp #$01
        bcs _csb_attic

        ; $0xxxx → bank 4
        lda #$04
        sta temp32+2
        lda #$00
        sta temp32+3
        rts

_csb_f_seg:
        ; $Fxxxx → bank 5
        lda #$05
        sta temp32+2
        lda #$00
        sta temp32+3
        rts

_csb_attic:
        ; $1xxxx–$Exxxx — can't pre-compute a fast base for attic
        ; We'll flag this and fall through to per-access cache lookups
        ; For now: map to bank 4 + offset (will wrap but at least won't crash)
        ; TODO: proper attic segment base caching
        lda #$04
        sta temp32+2
        lda #$00
        sta temp32+3
        rts