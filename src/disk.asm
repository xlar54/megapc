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

FLOPPY_CYLS     = 80
FLOPPY_HEADS    = 2
FLOPPY_SPT      = 18
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
        cmp #$08
        beq _i13_get_params

        ; Unsupported function: return error
        lda #$01                ; Invalid function
        sta reg_ah
        lda #1
        sta flag_cf             ; CF=1 = error
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
        ; Return parameters for 1.44MB floppy
        lda #$00
        sta reg_ah              ; Status = OK
        lda #FLOPPY_SPT
        sta reg_cl              ; Sectors per track in CL bits 0–5
        lda #(FLOPPY_CYLS-1)
        sta reg_ch              ; Max cylinder in CH
        lda #(FLOPPY_HEADS-1)
        sta reg_dh              ; Max head
        lda #$01
        sta reg_dl              ; Number of drives
        lda #$04
        sta reg_bl              ; Drive type (1.44MB)
        lda #0
        sta flag_cf
        rts

_i13_no_drive:
        lda #$01
        sta reg_ah
        lda #1
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

        ; Compute LBA from CHS
        ; LBA = (C × 2 + H) × 18 + (S - 1)
        ; C = CH + (CL >> 6 << 8) — for floppy, CL bits 6–7 are always 0
        lda reg_ch              ; Cylinder
        sta scratch_b           ; C

        ; C × 2 (heads_per_cyl = 2)
        asl scratch_b           ; C × 2
        ; + H
        clc
        lda scratch_b
        adc reg_dh              ; + head
        sta scratch_b           ; = C×2 + H

        ; × 18 (sectors_per_track)
        ; Use hardware multiplier at $D770
        lda scratch_b
        sta $D770               ; Multiplier input A (low)
        lda #0
        sta $D771               ; Multiplier input A (high)
        lda #FLOPPY_SPT
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
        lda floppy_ofs+2
        ora #$10                ; Add $100000 offset (FLOPPY_ATTIC - $8000000 = $100000)
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

        ; Check if destination is in chip RAM or attic
        lda temp32+2
        beq _i13_dest_chip      ; $0xxxx = bank 4 chip RAM
        cmp #$0F
        beq _i13_dest_chip      ; $Fxxxx = bank 5 chip RAM (unlikely but safe)
        bra _i13_dest_attic     ; $1xxxx-$Exxxx = attic
_i13_dest_chip:
        ; Destination is in chip RAM — safe to DMA 512 bytes directly
        jsr linear_to_chip
        lda #<SECTOR_BUF
        sta dma_src_lo
        lda #>SECTOR_BUF
        sta dma_src_hi
        lda #$00
        sta dma_src_bank
        lda temp_ptr
        sta dma_dst_lo
        lda temp_ptr+1
        sta dma_dst_hi
        lda temp_ptr+2
        sta dma_dst_bank
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_chip_copy
        bra _i13_advance

_i13_dest_attic:
        ; Destination is in attic — DMA 512 bytes directly to attic
        ; temp32 has 20-bit linear address
        ; Attic address = $8000000 + temp32 (20-bit)
        ; DMA dest: MB = $80, bank = temp32+2, addr = temp32+1:temp32
        lda #<SECTOR_BUF
        sta dma_src_lo
        lda #>SECTOR_BUF
        sta dma_src_hi
        lda #$00
        sta dma_src_bank
        lda temp32
        sta dma_dst_lo
        lda temp32+1
        sta dma_dst_hi
        lda temp32+2
        sta dma_dst_bank
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_to_attic
        ; INVALIDATE (not flush!) cache lines — the attic has fresh data,
        ; flushing would overwrite it with stale cached data
        jsr cache_invalidate_all

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