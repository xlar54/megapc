; ============================================================================
; disk.asm — Disk I/O (INT 13h)
; ============================================================================
;
; Handles BIOS INT 13h disk services.
; Floppy image is stored in attic RAM at FLOPPY_ATTIC ($8100000).
;
; Supported functions:
;   AH=00: Reset disk
;   AH=02: Read sectors
;   AH=08: Get drive parameters
;
; CHS → LBA conversion:
;   LBA = (C × heads_per_cyl + H) × sectors_per_track + (S - 1)
;   Byte offset = LBA × 512
;
; For 1.44MB floppy: 80 cylinders, 2 heads, 18 sectors/track

; Floppy geometry is now auto-detected — see floppy_spt/heads/cyls in zeropage.asm
FLOPPY_SECTOR_SZ = 512

; ============================================================================
; int13_handler — BIOS INT 13h dispatch
; ============================================================================
; Called when INT 13h is intercepted.
; 8086 registers available in ZP.
;
int13_handler:
        lda reg_ah
        cmp #$00
        beq _i13_reset
        cmp #$02
        beq _i13_read
        cmp #$03
        beq _i13_write
        cmp #$04
        beq _i13_verify
        cmp #$08
        beq _i13_get_params
        cmp #$15
        beq _i13_get_type

        ; Unsupported function: log and return error
        sta $8FD2               ; Save the unsupported AH value
        inc $8FD3               ; Count unsupported calls
        lda #$01                ; Invalid function
        sta reg_ah
        lda #1
        sta flag_cf             ; CF=1 = error
        rts

_i13_verify:
        ; AH=04: Verify sectors — always succeed (no actual verification)
        lda #$00
        sta reg_ah
        lda #0
        sta flag_cf
        rts

_i13_get_type:
        ; AH=15: Get disk type
        ; DL=0 (floppy): return AH=01 (floppy without change-line)
        ; DL>=80 (hard disk): return AH=03 (fixed disk)
        lda reg_dl
        beq _i13_gt_floppy
        bmi _i13_gt_harddisk    ; DL >= $80
        ; Floppy drive > 0: no drive
        lda #$00
        sta reg_ah
        lda #1
        sta flag_cf
        rts
_i13_gt_floppy:
        lda #$01                ; Floppy without change-line
        sta reg_ah
        lda #0
        sta flag_cf
        rts
_i13_gt_harddisk:
        lda #$03                ; Fixed disk present
        sta reg_ah
        lda #0
        sta flag_cf
        ; CX:DX = number of 512-byte sectors (return 0 = unknown)
        lda #0
        sta reg_cx
        sta reg_cx+1
        sta reg_dx
        sta reg_dx+1
        rts

_i13_reset:
        ; AH=00: Reset — always succeed
        lda #$00
        sta reg_ah
        lda #0
        sta flag_cf
        rts

_i13_get_params:
        ; AH=08: Get drive parameters
        ; DL = drive (0 = floppy A:)
        lda reg_dl
        bne _i13_no_drive
        ; Return parameters for detected floppy geometry
        lda #$00
        sta reg_ah              ; Status = OK
        lda floppy_spt
        sta reg_cl              ; Sectors per track in CL bits 0–5
        lda floppy_cyls
        sec
        sbc #1
        sta reg_ch              ; Max cylinder (cyls - 1)
        lda floppy_heads
        sec
        sbc #1
        sta reg_dh              ; Max head (heads - 1)
        lda #$01
        sta reg_dl              ; Number of drives
        lda floppy_type
        sta reg_bl              ; Drive type
        ; ES:DI = pointer to disk parameter table at F000:F000
        lda #$00
        sta reg_di
        sta reg_es
        lda #$F0
        sta reg_di+1
        sta reg_es+1
        ; Write disk parameter table to $5F000 (F000:F000)
        jsr _i13_write_dpt
        lda #0
        sta flag_cf
        rts

_i13_no_drive:
        ; Check if this is a hard disk query (DL >= $80)
        lda reg_dl
        bmi _i13_hard_disk
        ; Floppy drive > 0 — return timeout error
        lda #$80                ; Timeout / drive not ready
        sta reg_ah
        lda #0
        sta reg_al              ; 0 sectors transferred
        lda #$01
        sta reg_dl              ; Only 1 floppy drive
        lda #1
        sta flag_cf
        rts

_i13_hard_disk:
        ; Hard disk (DL >= $80): check function
        lda reg_ah
        cmp #$02
        beq _i13_hd_read
        cmp #$08
        beq _i13_hd_params
        ; All other functions: return error
        lda #$01
        sta reg_ah
        lda #0
        sta reg_dl              ; 0 hard drives
        lda #1
        sta flag_cf
        rts

_i13_hd_params:
        ; AH=08 for hard disk: return 1 drive with minimal geometry
        ; This makes FreeDOS try to read the partition table (gets zeros = invalid)
        ; which matches the reference emulator behavior ("illegal partition table")
        lda #$00
        sta reg_ah              ; Status OK
        lda #$01
        sta reg_dl              ; 1 hard drive
        lda #$01
        sta reg_cl              ; 1 sector per track
        lda #$00
        sta reg_ch              ; 0 cylinders (max)
        sta reg_dh              ; 0 heads (max)
        lda #0
        sta flag_cf             ; CF=0 = success
        rts

_i13_hd_read:
        ; AH=02 for hard disk: return a blank sector (all zeros)
        ; This makes FreeDOS read it and find "illegal partition table"
        ; instead of "no hard disks", taking the same code path as real PC
        lda reg_bx
        sta temp32
        lda reg_bx+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3
        ldx #SEG_ES_OFS
        lda #0
        sta seg_override_en
        jsr seg_ofs_to_linear
        jsr linear_to_chip
        ; Fill 512 bytes with zeros at ES:BX
        lda #$00
        ldy #0
_i13_hd_fill:
        tya
        taz
        lda #$00
        sta [temp_ptr],z
        iny
        bne _i13_hd_fill
        inc temp_ptr+1
        ldy #0
_i13_hd_fill2:
        tya
        taz
        lda #$00
        sta [temp_ptr],z
        iny
        bne _i13_hd_fill2
        ; Return success
        lda #$00
        sta reg_ah
        lda reg_al              ; Sectors requested = sectors read
        lda #0
        sta flag_cf
        rts

; ============================================================================
; _i13_read — Read sectors from floppy image
; ============================================================================
; Input:
;   AL = number of sectors to read
;   CH = cylinder (low 8 bits)
;   CL = sector (bits 0–5), cylinder hi (bits 6–7)
;   DH = head
;   DL = drive (0)
;   ES:BX = destination buffer
;
_i13_read:
        lda reg_dl
        bne _i13_no_drive       ; Only drive 0
        ; Debug: count reads
        inc $8F20

        ; Check if floppy image is loaded
        lda floppy_loaded
        beq _i13_no_drive       ; No floppy → error

        ; Save sector count
        lda reg_al
        sta disk_sect_left      ; sector count (safe from seg_ofs_to_linear)
        sta $8FF0               ; save original count for return (safe location)

        ; Save BX — real BIOS preserves BX, caller advances it
        lda reg_bx
        sta $8FF2
        lda reg_bx+1
        sta $8FF3

        ; Compute LBA from CHS
        ; LBA = (C × heads + H) × SPT + (S - 1)
        ; C = CH + (CL >> 6 << 8) — for floppy, CL bits 6–7 are always 0
        lda reg_ch              ; Cylinder
        ; C × heads (use hardware multiplier)
        sta $D770
        lda #0
        sta $D771
        lda floppy_heads
        sta $D774
        lda #0
        sta $D775
        lda $D778               ; Result low = C × heads
        ; + H
        clc
        adc reg_dh              ; + head
        sta scratch_b           ; = C×heads + H

        ; × sectors_per_track
        ; Use hardware multiplier at $D770
        lda scratch_b
        sta $D770               ; Multiplier input A (low)
        lda #0
        sta $D771               ; Multiplier input A (high)
        lda floppy_spt
        sta $D774               ; Multiplier input B (low)
        lda #0
        sta $D775               ; Multiplier input B (high)
        ; Result at $D778 (32-bit)
        lda $D778
        sta scratch_b
        lda $D779
        sta scratch_c           ; scratch_b:scratch_c = (C×2+H) × 18

        ; + (S - 1)
        lda reg_cl
        and #$3F                ; Sector number (bits 0–5)
        sec
        sbc #1                  ; S - 1
        clc
        adc scratch_b
        sta scratch_b
        lda scratch_c
        adc #0
        sta scratch_c           ; scratch_c:scratch_b = LBA

        ; Byte offset = LBA × 512
        ; Shift left 9 bits: high byte = LBA × 2, carry into byte 2
        ; LBA is 16-bit in scratch_c:scratch_b
        lda scratch_b
        asl                     ; × 2
        sta scratch_d           ; Low byte of (LBA << 1) — but we need << 9
        ; Actually: LBA × 512 = LBA << 9
        ; If LBA fits in 16 bits:
        ;   byte 0 = 0 (because << 9 means low byte is always 0)
        ;   byte 1 = LBA_lo << 1
        ;   byte 2 = (LBA_lo >> 7) | (LBA_hi << 1)
        lda #0
        sta temp32              ; byte offset low = 0
        lda scratch_b
        asl
        sta temp32+1            ; byte 1
        lda scratch_b
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        sta temp32+2            ; high bit of scratch_b
        lda scratch_c
        asl
        ora temp32+2
        sta temp32+2            ; byte 2
        ; temp32 = byte offset in floppy image (up to 20 bits)

        ; Now DMA each sector from attic to guest RAM (ES:BX)
        ; Source: FLOPPY_ATTIC + byte_offset
        ; Dest: ES:BX mapped to chip RAM

        ; Save floppy byte offset to dedicated variable (temp32 gets clobbered)
        lda temp32
        sta floppy_ofs
        lda temp32+1
        sta floppy_ofs+1
        lda temp32+2
        sta floppy_ofs+2

        ; For each sector:
_i13_read_loop:
        lda disk_sect_left      ; Sectors remaining
        beq _i13_read_done

        ; DMA 512 bytes from floppy attic to SECTOR_BUF
        clc
        lda floppy_ofs+2
        adc #$10                ; Add $100000 offset (FLOPPY_ATTIC - $8000000 = $100000)
        sta dma_src_bank
        lda floppy_ofs
        sta dma_src_lo
        lda floppy_ofs+1
        sta dma_src_hi

        ; Dest: SECTOR_BUF in chip RAM
        lda #<SECTOR_BUF
        sta dma_dst_lo
        lda #>SECTOR_BUF
        sta dma_dst_hi
        lda #$00
        sta dma_dst_bank

        ; Count: 512 bytes
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi

        jsr do_dma_from_attic

        ; Now copy SECTOR_BUF to ES:BX in guest memory
        ; First compute the linear address of ES:BX
        lda reg_bx
        sta temp32
        lda reg_bx+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3
        ldx #SEG_ES_OFS
        lda #0
        sta seg_override_en     ; Don't use override for this
        jsr seg_ofs_to_linear
        ; temp32 now has 20-bit linear address

        ; Check if destination is in attic (>= $10000)
        lda temp32+2
        beq _i13_copy_bank4
        ; Attic destination: DMA 512 bytes from SECTOR_BUF to attic directly
        ; This bypasses the cache entirely — much faster and avoids cache bugs
        jsr cache_flush_all     ; Flush any dirty cache data first
        jsr cache_invalidate_all ; Invalidate data cache (we're writing attic directly)
        ; Also invalidate code cache — attic DMA may overwrite code pages
        lda #CACHE_INVALID
        sta code_cache_pg_lo
        sta code_cache_pg_hi
        ; Source: SECTOR_BUF in chip RAM
        lda #<SECTOR_BUF
        sta dma_src_lo
        lda #>SECTOR_BUF
        sta dma_src_hi
        lda #$00
        sta dma_src_bank
        ; Dest: attic at linear temp32
        lda temp32
        sta dma_dst_lo
        lda temp32+1
        sta dma_dst_hi
        lda temp32+2
        sta dma_dst_bank
        ; Count: 512 bytes
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_to_attic
        bra _i13_copy_done

_i13_copy_bank4:
        ; Bank 4 destination: copy byte by byte (handles < $10000)
        ; Use [temp_ptr],z for direct bank 4 writes
        jsr linear_to_chip      ; Map first byte address
        ldy #0
_i13_copy_loop:
        lda SECTOR_BUF,y
        ldz #0
        sta [temp_ptr],z
        ; Advance pointer
        inc temp_ptr
        bne +
        inc temp_ptr+1
+       iny
        bne _i13_copy_loop
        ; Second 256 bytes
        ldy #0
_i13_copy_loop2:
        lda SECTOR_BUF+256,y
        ldz #0
        sta [temp_ptr],z
        inc temp_ptr
        bne +
        inc temp_ptr+1
+       iny
        bne _i13_copy_loop2
_i13_copy_done:

_i13_advance:

        ; Advance BX by 512
        clc
        lda reg_bx
        adc #$00
        sta reg_bx
        lda reg_bx+1
        adc #$02                ; +512
        sta reg_bx+1

        ; Advance floppy offset by 512
        clc
        lda floppy_ofs
        adc #$00
        sta floppy_ofs
        lda floppy_ofs+1
        adc #$02
        sta floppy_ofs+1
        lda floppy_ofs+2
        adc #0
        sta floppy_ofs+2

        dec disk_sect_left
        jmp _i13_read_loop

_i13_read_done:
        ; Restore BX — real BIOS preserves BX
        lda $8FF2
        sta reg_bx
        lda $8FF3
        sta reg_bx+1
        ; Return success
        lda #$00
        sta reg_ah
        lda $8FF0               ; restore original sector count
        sta reg_al              ; AL = sectors actually read
        lda #0
        sta flag_cf
        ; Debug: save state snapshot at $8FA0 (overwritten each call)
        lda reg_es
        sta $8FA0
        lda reg_es+1
        sta $8FA1
        lda reg_bx
        sta $8FA2
        lda reg_bx+1
        sta $8FA3
        lda reg_di
        sta $8FA4
        lda reg_di+1
        sta $8FA5
        lda reg_ds
        sta $8FA6
        lda reg_ds+1
        sta $8FA7
        lda flag_cf
        sta $8FA8
        rts

; ============================================================================
; _i13_write — Write sectors to floppy image (AH=03)
; ============================================================================
; Input: same as _i13_read (AL=count, CH/CL=cyl/sec, DH=head, ES:BX=buffer)
; Reads data from ES:BX, writes to floppy image in attic.
;
_i13_write:
        lda reg_dl
        bne _i13_no_drive       ; Only drive 0

        lda floppy_loaded
        beq _i13_no_drive

        ; Save sector count and BX
        lda reg_al
        sta disk_sect_left
        sta $8FF0
        lda reg_bx
        sta $8FF2
        lda reg_bx+1
        sta $8FF3

        ; Compute LBA from CHS (same as read)
        lda reg_ch
        sta $D770
        lda #0
        sta $D771
        lda floppy_heads
        sta $D774
        lda #0
        sta $D775
        lda $D778
        clc
        adc reg_dh
        sta scratch_b

        lda scratch_b
        sta $D770
        lda #0
        sta $D771
        lda floppy_spt
        sta $D774
        lda #0
        sta $D775
        lda $D778
        sta scratch_b
        lda $D779
        sta scratch_c

        lda reg_cl
        and #$3F
        sec
        sbc #1
        clc
        adc scratch_b
        sta scratch_b
        lda scratch_c
        adc #0
        sta scratch_c

        ; LBA to byte offset
        lda #0
        sta temp32
        lda scratch_b
        asl
        sta temp32+1
        lda scratch_b
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        sta temp32+2
        lda scratch_c
        asl
        ora temp32+2
        sta temp32+2

        lda temp32
        sta floppy_ofs
        lda temp32+1
        sta floppy_ofs+1
        lda temp32+2
        sta floppy_ofs+2

_i13_write_loop:
        lda disk_sect_left
        beq _i13_write_done

        ; Read 512 bytes from ES:BX into SECTOR_BUF
        lda reg_bx
        sta temp32
        lda reg_bx+1
        sta temp32+1
        lda #0
        sta temp32+2
        sta temp32+3
        ldx #SEG_ES_OFS
        lda #0
        sta seg_override_en
        jsr seg_ofs_to_linear

        ; Flush cache before reading (data may be in cache)
        jsr cache_flush_all

        ; Check if source is in attic or bank 4
        lda temp32+2
        beq _i13w_bank4_read
        ; Attic source: DMA from attic to SECTOR_BUF
        lda temp32
        sta dma_src_lo
        lda temp32+1
        sta dma_src_hi
        lda temp32+2
        sta dma_src_bank
        lda #<SECTOR_BUF
        sta dma_dst_lo
        lda #>SECTOR_BUF
        sta dma_dst_hi
        lda #$00
        sta dma_dst_bank
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_from_attic
        bra _i13w_do_write

_i13w_bank4_read:
        ; Bank 4 source: copy 512 bytes via [ptr],z
        jsr linear_to_chip
        ldy #0
_i13w_rd_loop:
        tya
        taz
        lda [temp_ptr],z
        sta SECTOR_BUF,y
        iny
        bne _i13w_rd_loop
        ; Advance temp_ptr by 256 for second half
        inc temp_ptr+1
        ldy #0
_i13w_rd_loop2:
        tya
        taz
        lda [temp_ptr],z
        sta SECTOR_BUF+256,y
        iny
        bne _i13w_rd_loop2

_i13w_do_write:
        ; DMA 512 bytes from SECTOR_BUF to floppy attic
        lda #<SECTOR_BUF
        sta dma_src_lo
        lda #>SECTOR_BUF
        sta dma_src_hi
        lda #$00
        sta dma_src_bank
        clc
        lda floppy_ofs+2
        adc #$10
        sta dma_dst_bank
        lda floppy_ofs
        sta dma_dst_lo
        lda floppy_ofs+1
        sta dma_dst_hi
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_to_attic

        ; Advance BX by 512
        clc
        lda reg_bx
        adc #$00
        sta reg_bx
        lda reg_bx+1
        adc #$02
        sta reg_bx+1

        ; Advance floppy offset by 512
        clc
        lda floppy_ofs
        adc #$00
        sta floppy_ofs
        lda floppy_ofs+1
        adc #$02
        sta floppy_ofs+1
        lda floppy_ofs+2
        adc #0
        sta floppy_ofs+2

        dec disk_sect_left
        jmp _i13_write_loop

_i13_write_done:
        ; Restore BX
        lda $8FF2
        sta reg_bx
        lda $8FF3
        sta reg_bx+1
        lda #$00
        sta reg_ah
        lda $8FF0
        sta reg_al
        lda #0
        sta flag_cf
        rts

; ============================================================================
; _i13_write_dpt — Write disk parameter table to F000:F000
; ============================================================================
; Standard 11-byte disk parameter table for INT 1Eh / AH=08
;
_i13_write_dpt:
        lda #$00
        sta temp_ptr
        lda #$F0
        sta temp_ptr+1
        lda #$05                ; Bank 5 (F000 segment)
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda #$CF                ; Byte 0: SRT/HUT (step rate 0xC, head unload 0xF)
        sta [temp_ptr],z
        ldz #1
        lda #$02                ; Byte 1: DMA/HLT (head load time)
        sta [temp_ptr],z
        ldz #2
        lda #$25                ; Byte 2: Motor off delay (ticks)
        sta [temp_ptr],z
        ldz #3
        lda #$02                ; Byte 3: Bytes per sector (2 = 512 bytes)
        sta [temp_ptr],z
        ldz #4
        lda floppy_spt          ; Byte 4: Sectors per track
        sta [temp_ptr],z
        ldz #5
        lda #$2A                ; Byte 5: Gap length
        sta [temp_ptr],z
        ldz #6
        lda #$FF                ; Byte 6: Data length
        sta [temp_ptr],z
        ldz #7
        lda #$50                ; Byte 7: Format gap length
        sta [temp_ptr],z
        ldz #8
        lda #$F6                ; Byte 8: Format fill byte
        sta [temp_ptr],z
        ldz #9
        lda #$0F                ; Byte 9: Head settle time (ms)
        sta [temp_ptr],z
        ldz #10
        lda #$08                ; Byte 10: Motor start time (1/8 sec)
        sta [temp_ptr],z
        rts