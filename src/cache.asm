; ============================================================================
; cache.asm — Attic RAM DMA Cache
; ============================================================================
;
; 4-line round-robin cache, 256 bytes per line.
; Maps 8086 addresses $10000–$EFFFF which live in attic RAM.
; Attic is not accessible via [ptr],z — must use DMA.
;
; Cache buffer: CACHE_BUF ($9200–$95FF) = 4 × 256 bytes
; ZP state:
;   cache_page_hi[0..3] at $90  — bits 16–19 of cached page
;   cache_page_lo[0..3] at $94  — bits 8–15 of cached page
;   cache_dirty[0..3]   at $98  — dirty flag per line
;   cache_next_line     at $9C  — round-robin pointer
;
; A "page" is a 256-byte aligned block: page_hi:page_lo:xx
; where page_hi = temp32+2, page_lo = temp32+1, offset = temp32+0

; ============================================================================
; init_cache — Initialize all cache lines as invalid
; ============================================================================
init_cache:
        ldx #CACHE_LINES-1
-       lda #CACHE_INVALID
        sta cache_page_hi,x
        sta cache_page_lo,x
        lda #0
        sta cache_dirty,x
        dex
        bpl -
        lda #0
        sta cache_next_line
        ; Initialize code cache as invalid
        lda #CACHE_INVALID
        sta code_cache_pg_lo
        sta code_cache_pg_hi
        lda #0
        sta cs_in_attic
        rts

; ============================================================================
; cache_access — Look up or load a page, return pointer
; ============================================================================
; Input:  temp32+0..+2 = 20-bit linear address ($10000–$EFFFF)
; Output: temp_ptr+0..+3 = pointer to byte in cache buffer
;
cache_access:
        ; Search all 4 lines for a hit
        ldx #0
_ca_search:
        lda temp32+1
        cmp cache_page_lo,x
        bne _ca_next
        lda temp32+2
        cmp cache_page_hi,x
        beq _ca_hit
_ca_next:
        inx
        cpx #CACHE_LINES
        bne _ca_search

        ; Cache miss — evict and load
        jsr cache_evict_load
        ; X = line that was loaded
        ; Fall through to hit

_ca_hit:
        ; Return pointer: CACHE_BUF + (X * 256) + offset
        ; X = cache line (0–3)
        lda #<CACHE_BUF
        sta temp_ptr
        lda #>CACHE_BUF
        clc
        txa                     ; Line 0 = +$00, 1 = +$01, 2 = +$02, 3 = +$03
        adc #>CACHE_BUF         ; Add to high byte (each line is 256 bytes = +1 page)
        sta temp_ptr+1
        lda #$00
        sta temp_ptr+2
        sta temp_ptr+3          ; Bank 0

        ; Add offset within page
        lda temp32              ; Low byte = offset within 256-byte page
        clc
        adc temp_ptr
        sta temp_ptr
        bcc +
        inc temp_ptr+1
+
        ; Mark dirty (conservative)
        lda #1
        sta cache_dirty,x
        rts

; ============================================================================
; cache_evict_load — Evict next line (flush if dirty), load new page
; ============================================================================
; Input:  temp32+1/+2 = page to load
; Output: X = cache line used
;
cache_evict_load:
        ldx cache_next_line

        ; Flush if dirty
        lda cache_dirty,x
        beq _cel_no_flush
        jsr cache_flush_line    ; Flush line X back to attic
_cel_no_flush:

        ; Record new page
        lda temp32+1
        sta cache_page_lo,x
        lda temp32+2
        sta cache_page_hi,x
        lda #0
        sta cache_dirty,x

        ; DMA load 256 bytes from attic to cache buffer
        jsr cache_dma_load

        ; Advance round-robin
        lda cache_next_line
        inc a
        and #(CACHE_LINES-1)    ; Wrap 0–3
        sta cache_next_line

        rts

; ============================================================================
; cache_mark_dirty — Mark current cache line as dirty (call after writes)
; ============================================================================
; Input: X = cache line index
cache_mark_dirty:
        lda #1
        sta cache_dirty,x
        rts

; ============================================================================
; cache_flush_line — Write dirty cache line X back to attic via DMA
; ============================================================================
; Input: X = cache line to flush
;
cache_flush_line:
        ; Source: CACHE_BUF + (X * 256) in chip RAM
        ; Dest:   attic at $8000000 + (page_hi:page_lo:00)

        ; Build DMA list for flush (chip → attic)
        ; Source address
        lda #<CACHE_BUF
        sta dma_src_lo
        lda #>CACHE_BUF
        clc
        txa
        adc #>CACHE_BUF
        sta dma_src_hi
        lda #$00
        sta dma_src_bank        ; Bank 0

        ; Dest address in attic: $80 + page_hi : page_lo : $00
        lda #$00
        sta dma_dst_lo
        lda cache_page_lo,x
        sta dma_dst_hi
        lda cache_page_hi,x
        sta dma_dst_bank        ; This becomes the MB (mega-byte) in attic

        ; Count = 256
        lda #$00
        sta dma_count_lo
        lda #$01
        sta dma_count_hi

        ; Trigger DMA: copy chip → attic
        jsr do_dma_to_attic

        ; Clear dirty
        lda #0
        sta cache_dirty,x
        rts

; ============================================================================
; cache_dma_load — DMA 256 bytes from attic to cache line X
; ============================================================================
; Input: X = cache line, cache_page_lo/hi[X] = page address
;
cache_dma_load:
        ; Source: attic at $80 + page_hi : page_lo : $00
        lda #$00
        sta dma_src_lo
        lda cache_page_lo,x
        sta dma_src_hi
        lda cache_page_hi,x
        sta dma_src_bank

        ; Dest: CACHE_BUF + (X * 256)
        lda #<CACHE_BUF
        sta dma_dst_lo
        lda #>CACHE_BUF
        clc
        txa
        adc #>CACHE_BUF
        sta dma_dst_hi
        lda #$00
        sta dma_dst_bank        ; Bank 0

        ; Count = 256
        lda #$00
        sta dma_count_lo
        lda #$01
        sta dma_count_hi

        ; Trigger DMA: copy attic → chip
        jsr do_dma_from_attic
        rts

; ============================================================================
; cache_flush_all — Flush all dirty cache lines (call before mode switch etc.)
; ============================================================================
cache_flush_all:
        ldx #0
-       lda cache_dirty,x
        beq +
        jsr cache_flush_line
+       inx
        cpx #CACHE_LINES
        bne -
        rts

; ============================================================================
; cache_invalidate_all — Discard all cache lines WITHOUT flushing to attic
; ============================================================================
; Use when attic has been written directly (e.g. DMA) and cached data is stale.
; This avoids the coherence bug where flushing would overwrite fresh attic data.
;
cache_invalidate_all:
        ldx #CACHE_LINES-1
-       lda #CACHE_INVALID
        sta cache_page_hi,x
        sta cache_page_lo,x
        lda #0
        sta cache_dirty,x
        dex
        bpl -
        rts

; ============================================================================
; DMA Engine Helpers
; ============================================================================
; MEGA65 Enhanced DMA using inline lists with sta $D707.
;
; $D707: write sets DMA list bank AND triggers Enhanced DMA.
;        The DMA controller reads the list from the bytes FOLLOWING
;        the sta $D707 instruction in the code stream.
;
; Inline list format:
;   $80 NN  — source megabyte option (NN = MB number)
;   $81 NN  — dest megabyte option
;   $00     — end of options
;   CC      — command ($00=copy, $03=fill)
;   LL HH   — count (16-bit, $0000 = 65536)
;   SL SH   — source addr (16-bit)
;   SB      — source bank (bits 16-19)
;   DL DH   — dest addr (16-bit)
;   DB      — dest bank (bits 16-19)
;   $00     — command high byte
;   $00 $00 — modulo
;
; Attic RAM is at megabyte $80+ ($8000000 = MB $80).
; Chip RAM is at megabyte $00.
;
; For patched (non-inline) DMA, we use dma_src/dst staging variables
; with self-modifying labels inside the inline lists.

; DMA parameter staging area (set by callers before jsr)
dma_src_lo      .byte 0
dma_src_hi      .byte 0
dma_src_bank    .byte 0
dma_dst_lo      .byte 0
dma_dst_hi      .byte 0
dma_dst_bank    .byte 0
dma_count_lo    .byte 0
dma_count_hi    .byte 0

; ============================================================================
; do_dma_from_attic — Copy attic → chip RAM
; ============================================================================
; Uses staged dma_src (attic) and dma_dst (chip) parameters.
; dma_src_bank: low nibble = bank within MB, high nibble = MB offset from $80
;   e.g., $01 = attic MB $80 bank 1 ($8010000)
;         $10 = attic MB $81 bank 0 ($8100000)
do_dma_from_attic:
        ; Patch the inline DMA list
        lda dma_src_lo
        sta _dfa_src
        lda dma_src_hi
        sta _dfa_src+1
        lda dma_src_bank
        and #$0F
        sta _dfa_src_bank
        ; Compute source MB: $80 + high nibble of src_bank
        lda dma_src_bank
        lsr
        lsr
        lsr
        lsr
        ora #$80
        sta _dfa_src_mb

        lda dma_dst_lo
        sta _dfa_dst
        lda dma_dst_hi
        sta _dfa_dst+1
        lda dma_dst_bank
        sta _dfa_dst_bank

        lda dma_count_lo
        sta _dfa_count
        lda dma_count_hi
        sta _dfa_count+1

        lda #$00
        sta $D707               ; Trigger — list follows inline
        .byte $80               ; Source MB option
_dfa_src_mb:
        .byte $80               ; Source MB value (patched)
        .byte $81               ; Dest MB option
        .byte $00               ; Dest MB = $00 (chip RAM)
        .byte $00               ; End options
        .byte $00               ; Command = COPY
_dfa_count:
        .word $0000             ; Count (patched)
_dfa_src:
        .word $0000             ; Source addr (patched)
_dfa_src_bank:
        .byte $00               ; Source bank (patched)
_dfa_dst:
        .word $0000             ; Dest addr (patched)
_dfa_dst_bank:
        .byte $00               ; Dest bank (patched)
        .byte $00               ; Command high
        .word $0000             ; Modulo
        rts

; ============================================================================
; do_dma_to_attic — Copy chip RAM → attic
; ============================================================================
do_dma_to_attic:
        lda dma_src_lo
        sta _dta_src
        lda dma_src_hi
        sta _dta_src+1
        lda dma_src_bank
        sta _dta_src_bank

        lda dma_dst_lo
        sta _dta_dst
        lda dma_dst_hi
        sta _dta_dst+1
        lda dma_dst_bank
        and #$0F
        sta _dta_dst_bank
        ; Compute dest MB
        lda dma_dst_bank
        lsr
        lsr
        lsr
        lsr
        ora #$80
        sta _dta_dst_mb

        lda dma_count_lo
        sta _dta_count
        lda dma_count_hi
        sta _dta_count+1

        lda #$00
        sta $D707
        .byte $80               ; Source MB option
        .byte $00               ; Source MB = $00 (chip RAM)
        .byte $81               ; Dest MB option
_dta_dst_mb:
        .byte $80               ; Dest MB value (patched)
        .byte $00               ; End options
        .byte $00               ; Command = COPY
_dta_count:
        .word $0000             ; Count (patched)
_dta_src:
        .word $0000             ; Source addr (patched)
_dta_src_bank:
        .byte $00               ; Source bank (patched)
_dta_dst:
        .word $0000             ; Dest addr (patched)
_dta_dst_bank:
        .byte $00               ; Dest bank (patched)
        .byte $00               ; Command high
        .word $0000             ; Modulo
        rts

; ============================================================================
; do_dma_chip_copy — Copy within chip RAM (no attic)
; ============================================================================
do_dma_chip_copy:
        lda dma_src_lo
        sta _dcc_src
        lda dma_src_hi
        sta _dcc_src+1
        lda dma_src_bank
        sta _dcc_src_bank
        lda dma_dst_lo
        sta _dcc_dst
        lda dma_dst_hi
        sta _dcc_dst+1
        lda dma_dst_bank
        sta _dcc_dst_bank
        lda dma_count_lo
        sta _dcc_count
        lda dma_count_hi
        sta _dcc_count+1

        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81, $00          ; Dest MB = 0
        .byte $00               ; End options
        .byte $00               ; Command = COPY
_dcc_count:
        .word $0000
_dcc_src:
        .word $0000
_dcc_src_bank:
        .byte $00
_dcc_dst:
        .word $0000
_dcc_dst_bank:
        .byte $00
        .byte $00
        .word $0000
        rts

; ============================================================================
; do_dma_fill — Fill chip RAM with a byte
; ============================================================================
; Input: dma_dst_lo/hi/bank, dma_count_lo/hi set. A = fill value.
do_dma_fill:
        sta _dfl_fillval
        lda dma_dst_lo
        sta _dfl_dst
        lda dma_dst_hi
        sta _dfl_dst+1
        lda dma_dst_bank
        sta _dfl_dst_bank
        lda dma_count_lo
        sta _dfl_count
        lda dma_count_hi
        sta _dfl_count+1

        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81, $00          ; Dest MB = 0
        .byte $00               ; End options
        .byte $03               ; Command = FILL
_dfl_count:
        .word $0000
_dfl_fillval:
        .byte $00               ; Fill value (source addr low)
        .byte $00
        .byte $00
_dfl_dst:
        .word $0000
_dfl_dst_bank:
        .byte $00
        .byte $00
        .word $0000
        rts

; ============================================================================
; do_dma_fill_attic — Fill attic RAM with a byte
; ============================================================================
; Input: dma_dst_lo/hi/bank, dma_count_lo/hi set. A = fill value.
; dma_dst_bank: low nibble = bank, high nibble = MB offset from $80
do_dma_fill_attic:
        sta _dfa2_fillval
        lda dma_dst_lo
        sta _dfa2_dst
        lda dma_dst_hi
        sta _dfa2_dst+1
        lda dma_dst_bank
        and #$0F
        sta _dfa2_dst_bank
        lda dma_dst_bank
        lsr
        lsr
        lsr
        lsr
        ora #$80
        sta _dfa2_dst_mb
        lda dma_count_lo
        sta _dfa2_count
        lda dma_count_hi
        sta _dfa2_count+1

        lda #$00
        sta $D707
        .byte $80, $00          ; Source MB = 0
        .byte $81               ; Dest MB option
_dfa2_dst_mb:
        .byte $80               ; Dest MB (patched)
        .byte $00               ; End options
        .byte $03               ; Command = FILL
_dfa2_count:
        .word $0000
_dfa2_fillval:
        .byte $00
        .byte $00
        .byte $00
_dfa2_dst:
        .word $0000
_dfa2_dst_bank:
        .byte $00
        .byte $00
        .word $0000
        rts