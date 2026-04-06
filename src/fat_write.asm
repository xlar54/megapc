; ============================================================================
; fat_write.asm — FAT32 file writer for saving floppy images to SD card
; ============================================================================
;
; Saves a floppy disk image from attic RAM back to the SD card FAT32
; filesystem. Uses raw SD card sector reads/writes via $D680/$D681.
;
; Flow:
;   1. hyppo_rmfile to delete old file (caller does this)
;   2. fat_open_filesystem — parse MBR + BPB
;   3. fat_create_file — create directory entry + allocate clusters
;   4. fat_write_file — DMA from attic, write sectors
;   5. fat_close_file — update directory entry with file size
;
; SD card hardware interface:
;   $D680     — SD command register
;              $02 = read sector, $03 = write sector, $57 = write gate
;   $D681-684 — SD sector number (32-bit, little-endian)
;   $D689     — bit 7: map SD buffer instead of floppy buffer
;   $FFD6E00  — 512-byte SD sector buffer
;
; All 32-bit values are little-endian.
; Uses SECTOR_BUF ($9800) as temp workspace.
;
; NOT YET INCLUDED IN BUILD — work in progress
; ============================================================================

; ============================================================================
; FAT32 state variables (stored in $8Exx area — unused by emulator)
; ============================================================================
fat_partition_start = $8E00     ; 4 bytes: SD sector of FAT32 partition
fat_sectors_per_cluster = $8E04 ; 1 byte
fat_reserved_sectors = $8E05    ; 2 bytes
fat_sectors_per_fat = $8E07     ; 4 bytes
fat_first_cluster = $8E0B       ; 4 bytes: root dir cluster number
fat_fat1_sector = $8E0F         ; 4 bytes: absolute SD sector of FAT1
fat_fat2_sector = $8E13         ; 4 bytes: absolute SD sector of FAT2
fat_data_sector = $8E17         ; 4 bytes: absolute SD sector of first data cluster
fat_dir_sector = $8E1B          ; 4 bytes: SD sector containing our dir entry
fat_dir_offset = $8E1F          ; 2 bytes: offset within dir sector (0-511)
fat_file_cluster = $8E21        ; 4 bytes: first cluster of file being written
fat_cur_cluster = $8E25         ; 4 bytes: current cluster being written
fat_sector_in_cluster = $8E29   ; 1 byte: sector index within current cluster
fat_file_size = $8E2A           ; 4 bytes: total file size in bytes
fat_remaining = $8E2E           ; 4 bytes: remaining bytes to write
fat_attic_bank = $8E32          ; 1 byte: attic source bank ($10=A, $20=B)
fat_attic_lo = $8E33            ; 2 bytes: current attic source offset
fat_attic_hi = $8E34

; Temp for 32-bit math
fat_tmp0 = $8E40                ; 4 bytes
fat_tmp1 = $8E44                ; 4 bytes

; ============================================================================
; sd_wait_ready — Wait for SD card to be ready
; ============================================================================
; Polls $D680 bits 0-1 until both clear.
; Returns: A = status byte
;
sd_wait_ready:
        lda $D680
        and #$03
        bne sd_wait_ready
        rts

; ============================================================================
; sd_read_sector — Read SD sector into SD buffer at $FFD6E00
; ============================================================================
; Input: fat_tmp0 (4 bytes) = sector number
;
sd_read_sector:
        jsr sd_wait_ready
        lda fat_tmp0
        sta $D681
        lda fat_tmp0+1
        sta $D682
        lda fat_tmp0+2
        sta $D683
        lda fat_tmp0+3
        sta $D684
        lda #$02                ; Read sector command
        sta $D680
        jsr sd_wait_ready
        rts

; ============================================================================
; sd_write_sector — Write SD buffer at $FFD6E00 to SD sector
; ============================================================================
; Input: fat_tmp0 (4 bytes) = sector number
;
sd_write_sector:
        jsr sd_wait_ready
        lda fat_tmp0
        sta $D681
        lda fat_tmp0+1
        sta $D682
        lda fat_tmp0+2
        sta $D683
        lda fat_tmp0+3
        sta $D684
        lda #$57                ; Write gate unlock
        sta $D680
        lda #$03                ; Write sector command
        sta $D680
        jsr sd_wait_ready
        rts

; ============================================================================
; sd_buf_to_chip — Copy 512 bytes from SD buffer ($FFD6E00) to chip RAM
; ============================================================================
; Input: fat_tmp1 = destination address (32-bit)
;
sd_buf_to_chip:
        lda #$00
        sta dma_src_lo
        lda #$6E
        sta dma_src_hi
        lda #$0D
        sta dma_src_bank        ; $FFD6E00 → bank $0D, addr $6E00
        lda fat_tmp1
        sta dma_dst_lo
        lda fat_tmp1+1
        sta dma_dst_hi
        lda fat_tmp1+2
        sta dma_dst_bank
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi        ; 512 bytes
        jsr do_dma_chip_copy
        rts

; ============================================================================
; chip_to_sd_buf — Copy 512 bytes from chip RAM to SD buffer ($FFD6E00)
; ============================================================================
; Input: fat_tmp1 = source address (32-bit)
;
chip_to_sd_buf:
        lda fat_tmp1
        sta dma_src_lo
        lda fat_tmp1+1
        sta dma_src_hi
        lda fat_tmp1+2
        sta dma_src_bank
        lda #$00
        sta dma_dst_lo
        lda #$6E
        sta dma_dst_hi
        lda #$0D
        sta dma_dst_bank        ; $FFD6E00
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_chip_copy
        rts

; ============================================================================
; attic_to_sd_buf — DMA 512 bytes from attic to SD buffer
; ============================================================================
; Input: fat_attic_bank, fat_attic_lo/hi = source in attic
;
attic_to_sd_buf:
        lda fat_attic_lo
        sta dma_src_lo
        lda fat_attic_hi
        sta dma_src_hi
        lda fat_attic_bank
        sta dma_src_bank
        lda #$00
        sta dma_dst_lo
        lda #$6E
        sta dma_dst_hi
        lda #$0D
        sta dma_dst_bank        ; SD buffer at $FFD6E00
        lda #$00
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_from_attic   ; Attic → chip (SD buffer is in chip space)
        rts

; ============================================================================
; fat_open_filesystem — Parse MBR and FAT32 BPB
; ============================================================================
; Reads MBR sector 0, finds FAT32 partition, reads BPB.
; Sets all fat_* state variables.
; Returns: carry set = success, carry clear = error
;
fat_open_filesystem:
        ; Enable SD buffer mapping
        lda $D689
        ora #$80
        sta $D689

        ; Read MBR (sector 0)
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
        jsr sd_read_sector

        ; Copy SD buffer to SECTOR_BUF for parsing
        lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #$00
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip

        ; Scan 4 partition entries for FAT32 (type $0B or $0C)
        ldx #0                  ; Partition index
_fof_scan:
        ; Entry at SECTOR_BUF + $1BE + (X * $10)
        txa
        asl
        asl
        asl
        asl                     ; × 16
        clc
        adc #$BE                ; + $BE (note: $1BE, but we're within 512 bytes)
        tay                     ; Y = offset from SECTOR_BUF + $100
        ; Type byte is at offset +4 within the entry
        ; But SECTOR_BUF+$1BE might cross pages...
        ; Simpler: compute absolute address
        ; Entry start = SECTOR_BUF + $1BE + X*16
        ; partition_start = bytes 8-11, type = byte 4
        txa
        asl
        asl
        asl
        asl                     ; × 16
        clc
        adc #<(SECTOR_BUF+$1BE)
        sta temp_ptr
        lda #>(SECTOR_BUF+$1BE)
        adc #0
        sta temp_ptr+1
        lda #0
        sta temp_ptr+2
        sta temp_ptr+3

        ; Check type byte at offset 4
        ldy #4
        lda (temp_ptr),y
        cmp #$0C                ; FAT32 LBA
        beq _fof_found
        cmp #$0B                ; FAT32 CHS
        beq _fof_found

        inx
        cpx #4
        bne _fof_scan
        ; No FAT32 partition found
        clc
        rts

_fof_found:
        ; Read partition_start (bytes 8-11 of entry)
        ldy #8
        lda (temp_ptr),y
        sta fat_partition_start
        iny
        lda (temp_ptr),y
        sta fat_partition_start+1
        iny
        lda (temp_ptr),y
        sta fat_partition_start+2
        iny
        lda (temp_ptr),y
        sta fat_partition_start+3

        ; Now read the FAT32 BPB (first sector of partition)
        lda fat_partition_start
        sta fat_tmp0
        lda fat_partition_start+1
        sta fat_tmp0+1
        lda fat_partition_start+2
        sta fat_tmp0+2
        lda fat_partition_start+3
        sta fat_tmp0+3
        jsr sd_read_sector

        ; Copy to SECTOR_BUF
        lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #$00
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip

        ; Parse BPB fields
        ; Sectors per cluster: offset $0D (1 byte)
        lda SECTOR_BUF+$0D
        sta fat_sectors_per_cluster

        ; Reserved sectors: offset $0E (2 bytes)
        lda SECTOR_BUF+$0E
        sta fat_reserved_sectors
        lda SECTOR_BUF+$0F
        sta fat_reserved_sectors+1

        ; Sectors per FAT: offset $24 (4 bytes)
        lda SECTOR_BUF+$24
        sta fat_sectors_per_fat
        lda SECTOR_BUF+$25
        sta fat_sectors_per_fat+1
        lda SECTOR_BUF+$26
        sta fat_sectors_per_fat+2
        lda SECTOR_BUF+$27
        sta fat_sectors_per_fat+3

        ; Root dir first cluster: offset $2C (4 bytes)
        lda SECTOR_BUF+$2C
        sta fat_first_cluster
        lda SECTOR_BUF+$2D
        sta fat_first_cluster+1
        lda SECTOR_BUF+$2E
        sta fat_first_cluster+2
        lda SECTOR_BUF+$2F
        sta fat_first_cluster+3

        ; Compute fat1_sector = partition_start + reserved_sectors
        clc
        lda fat_partition_start
        adc fat_reserved_sectors
        sta fat_fat1_sector
        lda fat_partition_start+1
        adc fat_reserved_sectors+1
        sta fat_fat1_sector+1
        lda fat_partition_start+2
        adc #0
        sta fat_fat1_sector+2
        lda fat_partition_start+3
        adc #0
        sta fat_fat1_sector+3

        ; fat2_sector = fat1_sector + sectors_per_fat
        clc
        lda fat_fat1_sector
        adc fat_sectors_per_fat
        sta fat_fat2_sector
        lda fat_fat1_sector+1
        adc fat_sectors_per_fat+1
        sta fat_fat2_sector+1
        lda fat_fat1_sector+2
        adc fat_sectors_per_fat+2
        sta fat_fat2_sector+2
        lda fat_fat1_sector+3
        adc fat_sectors_per_fat+3
        sta fat_fat2_sector+3

        ; data_sector = fat2_sector + sectors_per_fat
        ;             = first sector where cluster 2 data begins
        clc
        lda fat_fat2_sector
        adc fat_sectors_per_fat
        sta fat_data_sector
        lda fat_fat2_sector+1
        adc fat_sectors_per_fat+1
        sta fat_data_sector+1
        lda fat_fat2_sector+2
        adc fat_sectors_per_fat+2
        sta fat_data_sector+2
        lda fat_fat2_sector+3
        adc fat_sectors_per_fat+3
        sta fat_data_sector+3

        sec                     ; Success
        rts

; ============================================================================
; fat_cluster_to_sector — Convert cluster number to absolute SD sector
; ============================================================================
; Input:  fat_tmp0 = cluster number (32-bit)
; Output: fat_tmp0 = absolute SD sector number
;
; sector = data_sector + (cluster - 2) * sectors_per_cluster
;
fat_cluster_to_sector:
        ; cluster - 2
        sec
        lda fat_tmp0
        sbc #2
        sta fat_tmp0
        lda fat_tmp0+1
        sbc #0
        sta fat_tmp0+1
        lda fat_tmp0+2
        sbc #0
        sta fat_tmp0+2
        lda fat_tmp0+3
        sbc #0
        sta fat_tmp0+3

        ; × sectors_per_cluster (power of 2 assumed: 1,2,4,8,16,32,64)
        lda fat_sectors_per_cluster
        lsr                     ; Check if 1
        bcc _fcts_shift
        ; sectors_per_cluster = 1, no shift needed
        bra _fcts_add
_fcts_shift:
        ; Shift left until we've multiplied enough
        asl fat_tmp0
        rol fat_tmp0+1
        rol fat_tmp0+2
        rol fat_tmp0+3
        lsr                     ; Next bit
        bcs _fcts_add
        bra _fcts_shift

_fcts_add:
        ; + data_sector
        clc
        lda fat_tmp0
        adc fat_data_sector
        sta fat_tmp0
        lda fat_tmp0+1
        adc fat_data_sector+1
        sta fat_tmp0+1
        lda fat_tmp0+2
        adc fat_data_sector+2
        sta fat_tmp0+2
        lda fat_tmp0+3
        adc fat_data_sector+3
        sta fat_tmp0+3
        rts

; ============================================================================
; fat_find_free_cluster — Find first free cluster in FAT
; ============================================================================
; Returns: fat_tmp0 = free cluster number (0 = none found)
;          carry set = found, carry clear = not found
;
; Scans FAT1 sector by sector looking for a zero entry.
;
fat_find_free_cluster:
        ; Start scanning from cluster 2 (FAT sector 0, offset 8)
        lda #0
        sta fat_tmp0            ; FAT sector index (within FAT)
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3

_fffc_next_sector:
        ; Read FAT1 sector: fat1_sector + fat_tmp0
        clc
        lda fat_fat1_sector
        adc fat_tmp0
        sta fat_tmp1
        lda fat_fat1_sector+1
        adc fat_tmp0+1
        sta fat_tmp1+1
        lda fat_fat1_sector+2
        adc #0
        sta fat_tmp1+2
        lda fat_fat1_sector+3
        adc #0
        sta fat_tmp1+3

        ; Copy to fat_tmp0 for read (clobbers our index — save it)
        lda fat_tmp0
        pha
        lda fat_tmp0+1
        pha

        lda fat_tmp1
        sta fat_tmp0
        lda fat_tmp1+1
        sta fat_tmp0+1
        lda fat_tmp1+2
        sta fat_tmp0+2
        lda fat_tmp1+3
        sta fat_tmp0+3
        jsr sd_read_sector
        jsr sd_buf_to_chip      ; To SECTOR_BUF (fat_tmp1 still set)

        pla
        sta fat_tmp0+1
        pla
        sta fat_tmp0            ; Restore FAT sector index

        ; Scan SECTOR_BUF for zero 4-byte entries
        ; Each entry = 4 bytes, 128 entries per 512-byte sector
        ldy #0                  ; Offset within SECTOR_BUF
_fffc_scan:
        ; Check if all 4 bytes are zero
        lda SECTOR_BUF,y
        ora SECTOR_BUF+1,y
        ora SECTOR_BUF+2,y
        ora SECTOR_BUF+3,y
        beq _fffc_found

        ; Next entry
        tya
        clc
        adc #4
        tay
        cpy #0                  ; Wrapped past 256?
        beq _fffc_high_half
        bra _fffc_scan

_fffc_high_half:
        ; Scan second half (SECTOR_BUF+256)
        ldy #0
_fffc_scan2:
        lda SECTOR_BUF+256,y
        ora SECTOR_BUF+257,y
        ora SECTOR_BUF+258,y
        ora SECTOR_BUF+259,y
        beq _fffc_found2

        tya
        clc
        adc #4
        tay
        cpy #0
        beq _fffc_not_in_sector
        bra _fffc_scan2

_fffc_found2:
        ; Offset in second half: add 256
        tya
        clc
        adc #0                  ; Y already has offset within second 256
        ; cluster = fat_sector_index * 128 + (256 + Y) / 4
        ; Fall through with adjusted offset
        clc
        tya
        adc #0
        sta fat_tmp1            ; Save Y offset
        lda #1                  ; Flag: second half
        sta fat_tmp1+1
        bra _fffc_calc_cluster

_fffc_found:
        sty fat_tmp1            ; Save Y offset
        lda #0                  ; Flag: first half
        sta fat_tmp1+1

_fffc_calc_cluster:
        ; cluster = fat_tmp0 * 128 + (half*256 + Y) / 4
        ; fat_tmp0 = FAT sector index
        ; Multiply sector index by 128 (entries per sector)
        lda fat_tmp0
        sta fat_tmp0+2          ; Save original
        lda fat_tmp0+1
        sta fat_tmp0+3

        ; × 128 = shift left 7
        lda #0
        sta fat_tmp0
        lda fat_tmp0+2
        lsr                     ; High bit → carry
        sta fat_tmp0+1
        lda #0
        ror                     ; Carry → bit 7
        sta fat_tmp0            ; fat_tmp0 = sector_index * 128 (low 16 bits)
        lda fat_tmp0+3
        lsr
        ; (ignoring high bytes for now — cluster count < 65536 typical)

        ; Add offset / 4
        lda fat_tmp1            ; Y offset
        lsr
        lsr                     ; / 4
        clc
        adc fat_tmp0
        sta fat_tmp0
        lda fat_tmp0+1
        adc #0
        sta fat_tmp0+1

        ; If second half, add 64 (256/4)
        lda fat_tmp1+1
        beq _fffc_done
        clc
        lda fat_tmp0
        adc #64
        sta fat_tmp0
        lda fat_tmp0+1
        adc #0
        sta fat_tmp0+1

_fffc_done:
        lda #0
        sta fat_tmp0+2
        sta fat_tmp0+3
        sec                     ; Found
        rts

_fffc_not_in_sector:
        ; Try next FAT sector
        inc fat_tmp0
        bne +
        inc fat_tmp0+1
+
        ; Check if we've scanned all FAT sectors
        lda fat_tmp0
        cmp fat_sectors_per_fat
        bne _fffc_next_sector
        lda fat_tmp0+1
        cmp fat_sectors_per_fat+1
        bne _fffc_next_sector

        ; No free cluster found
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
        clc
        rts

; ============================================================================
; fat_set_cluster_value — Write a value to a FAT entry (both FAT1 and FAT2)
; ============================================================================
; Input:  fat_tmp0 = cluster number
;         fat_tmp1 = value to write (4 bytes)
;
fat_set_cluster_value:
        ; FAT sector = cluster / 128
        ; FAT offset = (cluster % 128) * 4
        lda fat_tmp0
        and #$7F                ; cluster % 128
        asl
        asl                     ; × 4
        sta $8E50               ; Save FAT offset within sector

        ; FAT sector index = cluster >> 7
        lda fat_tmp0+1
        asl                     ; Shift cluster >> 7 (low byte)
        sta $8E51               ; FAT sector index low
        lda fat_tmp0
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr                     ; >> 7
        ora $8E51
        sta $8E51
        lda fat_tmp0+1
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr                     ; upper bits >> 7
        sta $8E52

        ; Read FAT1 sector
        clc
        lda fat_fat1_sector
        adc $8E51
        sta fat_tmp0
        lda fat_fat1_sector+1
        adc $8E52
        sta fat_tmp0+1
        lda fat_fat1_sector+2
        adc #0
        sta fat_tmp0+2
        lda fat_fat1_sector+3
        adc #0
        sta fat_tmp0+3

        ; Save FAT1 absolute sector for write-back
        lda fat_tmp0
        sta $8E54
        lda fat_tmp0+1
        sta $8E55
        lda fat_tmp0+2
        sta $8E56
        lda fat_tmp0+3
        sta $8E57

        jsr sd_read_sector

        ; Copy to SECTOR_BUF
        lda #<SECTOR_BUF
        sta fat_tmp1+2          ; Reuse tmp1 high bytes (value already saved)
        ; Actually we need fat_tmp1 for the value... let me use stack
        ; This is getting complex. For now, patch the SD buffer directly
        ; via [ptr],z at $FFD6E00

        ; Patch the entry in the SD buffer directly
        ; SD buffer at $FFD6E00, offset = $8E50
        lda #$00
        sta temp_ptr
        lda #$6E
        sta temp_ptr+1
        lda #$0D
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldy $8E50               ; FAT offset
        lda fat_tmp1
        sta (temp_ptr),y
        iny
        lda fat_tmp1+1
        sta (temp_ptr),y
        iny
        lda fat_tmp1+2
        sta (temp_ptr),y
        iny
        lda fat_tmp1+3
        and #$0F                ; FAT32 uses only low 28 bits
        sta (temp_ptr),y

        ; Write back to FAT1
        lda $8E54
        sta fat_tmp0
        lda $8E55
        sta fat_tmp0+1
        lda $8E56
        sta fat_tmp0+2
        lda $8E57
        sta fat_tmp0+3
        jsr sd_write_sector

        ; Write same sector to FAT2
        ; FAT2 sector = FAT1 sector + sectors_per_fat
        clc
        lda $8E54
        adc fat_sectors_per_fat
        sta fat_tmp0
        lda $8E55
        adc fat_sectors_per_fat+1
        sta fat_tmp0+1
        lda $8E56
        adc fat_sectors_per_fat+2
        sta fat_tmp0+2
        lda $8E57
        adc fat_sectors_per_fat+3
        sta fat_tmp0+3
        jsr sd_write_sector
        rts

; ============================================================================
; fat_allocate_cluster — Mark a cluster as end-of-chain ($0FFFFFF8)
; ============================================================================
; Input: fat_tmp0 = cluster number
;
fat_allocate_cluster:
        lda #$F8
        sta fat_tmp1
        lda #$FF
        sta fat_tmp1+1
        sta fat_tmp1+2
        lda #$0F
        sta fat_tmp1+3
        jmp fat_set_cluster_value

; ============================================================================
; fat_chain_cluster — Chain one cluster to the next
; ============================================================================
; Input: fat_tmp0 = current cluster
;        fat_tmp1 = next cluster (4 bytes)
;
fat_chain_cluster:
        jmp fat_set_cluster_value

; ============================================================================
; fat_find_empty_direntry — Find empty slot in root directory
; ============================================================================
; Scans root directory cluster chain for an entry where byte 0 = $00 or $E5.
; Sets fat_dir_sector and fat_dir_offset on success.
; Returns: carry set = found, carry clear = directory full
;
fat_find_empty_direntry:
        ; Start with root directory first cluster
        lda fat_first_cluster
        sta fat_cur_cluster
        lda fat_first_cluster+1
        sta fat_cur_cluster+1
        lda fat_first_cluster+2
        sta fat_cur_cluster+2
        lda fat_first_cluster+3
        sta fat_cur_cluster+3

_ffed_next_cluster:
        ; Convert cluster to sector
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_cluster_to_sector
        ; fat_tmp0 = first sector of this cluster
        ; Save base sector
        lda fat_tmp0
        sta $8E58
        lda fat_tmp0+1
        sta $8E59
        lda fat_tmp0+2
        sta $8E5A
        lda fat_tmp0+3
        sta $8E5B

        ; Scan each sector in this cluster
        lda #0
        sta fat_sector_in_cluster
_ffed_next_sector:
        ; Read sector: base + sector_in_cluster
        clc
        lda $8E58
        adc fat_sector_in_cluster
        sta fat_tmp0
        lda $8E59
        adc #0
        sta fat_tmp0+1
        lda $8E5A
        adc #0
        sta fat_tmp0+2
        lda $8E5B
        adc #0
        sta fat_tmp0+3

        ; Save this sector number for potential write-back
        lda fat_tmp0
        sta fat_dir_sector
        lda fat_tmp0+1
        sta fat_dir_sector+1
        lda fat_tmp0+2
        sta fat_dir_sector+2
        lda fat_tmp0+3
        sta fat_dir_sector+3

        jsr sd_read_sector
        lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip

        ; Scan 16 directory entries per sector (32 bytes each)
        ldy #0                  ; Offset within SECTOR_BUF
_ffed_scan_entry:
        lda SECTOR_BUF,y
        beq _ffed_found         ; $00 = never used (end of dir)
        cmp #$E5
        beq _ffed_found         ; $E5 = deleted entry

        ; Next entry: +32
        tya
        clc
        adc #32
        tay
        beq _ffed_scan_high     ; Wrapped past 256 → second half
        cpy #0                  ; Safety check
        bra _ffed_scan_entry

_ffed_scan_high:
        ; Second half of sector
        ldy #0
_ffed_scan_entry2:
        lda SECTOR_BUF+256,y
        beq _ffed_found_high
        cmp #$E5
        beq _ffed_found_high

        tya
        clc
        adc #32
        tay
        beq _ffed_sector_done   ; Past 512 bytes
        bra _ffed_scan_entry2

_ffed_found_high:
        ; Offset = 256 + Y
        tya
        clc
        adc #0                  ; Y is already in low half range
        sta fat_dir_offset
        lda #1                  ; High byte = 1 (offset 256+)
        sta fat_dir_offset+1
        sec
        rts

_ffed_found:
        ; Found empty entry at offset Y
        sty fat_dir_offset
        lda #0
        sta fat_dir_offset+1
        sec
        rts

_ffed_sector_done:
        ; Try next sector in cluster
        inc fat_sector_in_cluster
        lda fat_sector_in_cluster
        cmp fat_sectors_per_cluster
        bcc _ffed_next_sector

        ; This cluster is full — follow the cluster chain
        ; Read FAT entry for current cluster to find next
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_read_cluster_value
        ; fat_tmp0 = next cluster
        ; Check for end-of-chain ($0FFFFFF8+)
        lda fat_tmp0+3
        and #$0F
        cmp #$0F
        bne _ffed_chain_ok
        lda fat_tmp0+2
        cmp #$FF
        bne _ffed_chain_ok
        lda fat_tmp0+1
        cmp #$FF
        bne _ffed_chain_ok
        lda fat_tmp0
        cmp #$F8
        bcs _ffed_dir_full      ; End of chain — no more dir sectors
_ffed_chain_ok:
        lda fat_tmp0
        sta fat_cur_cluster
        lda fat_tmp0+1
        sta fat_cur_cluster+1
        lda fat_tmp0+2
        sta fat_cur_cluster+2
        lda fat_tmp0+3
        sta fat_cur_cluster+3
        jmp _ffed_next_cluster

_ffed_dir_full:
        clc                     ; Directory full
        rts

; ============================================================================
; fat_read_cluster_value — Read a FAT entry value
; ============================================================================
; Input:  fat_tmp0 = cluster number
; Output: fat_tmp0 = FAT entry value (next cluster or end marker)
;
fat_read_cluster_value:
        ; FAT offset = cluster * 4
        ; FAT sector = cluster / 128
        ; Sector offset = (cluster % 128) * 4
        lda fat_tmp0
        and #$7F
        asl
        asl
        sta $8E50               ; Offset within sector

        ; Sector index = cluster >> 7
        lda fat_tmp0
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        sta $8E51
        lda fat_tmp0+1
        asl
        ora $8E51
        sta $8E51
        lda fat_tmp0+1
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        sta $8E52

        ; Read FAT1 sector
        clc
        lda fat_fat1_sector
        adc $8E51
        sta fat_tmp0
        lda fat_fat1_sector+1
        adc $8E52
        sta fat_tmp0+1
        lda fat_fat1_sector+2
        adc #0
        sta fat_tmp0+2
        lda fat_fat1_sector+3
        adc #0
        sta fat_tmp0+3
        jsr sd_read_sector

        ; Read the 4-byte entry from SD buffer directly
        lda #$00
        sta temp_ptr
        lda #$6E
        sta temp_ptr+1
        lda #$0D
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldy $8E50
        lda (temp_ptr),y
        sta fat_tmp0
        iny
        lda (temp_ptr),y
        sta fat_tmp0+1
        iny
        lda (temp_ptr),y
        sta fat_tmp0+2
        iny
        lda (temp_ptr),y
        and #$0F                ; FAT32 uses low 28 bits
        sta fat_tmp0+3
        rts

; ============================================================================
; fat_create_direntry — Write 8.3 directory entry at fat_dir_sector/offset
; ============================================================================
; Input:  floppy_fname_page = filename (null-terminated, e.g., "FD-MSDOS3.3.IMG")
;         fat_file_cluster = first cluster of file
; Precondition: fat_dir_sector/fat_dir_offset set by fat_find_empty_direntry
;
; Writes a 32-byte FAT32 directory entry with:
;   - 8.3 uppercase short name
;   - Archive attribute ($20)
;   - First cluster number
;   - File size (from fat_file_size)
;
fat_create_direntry:
        ; Re-read the directory sector into SD buffer
        lda fat_dir_sector
        sta fat_tmp0
        lda fat_dir_sector+1
        sta fat_tmp0+1
        lda fat_dir_sector+2
        sta fat_tmp0+2
        lda fat_dir_sector+3
        sta fat_tmp0+3
        jsr sd_read_sector

        ; Copy SD buffer to SECTOR_BUF for modification
        lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip

        ; Build 8.3 name from floppy_fname_page
        ; First clear the 32-byte entry with zeros
        ldy fat_dir_offset
        ldx #32
_fcd_clear:
        lda #0
        sta SECTOR_BUF,y
        iny
        dex
        bne _fcd_clear

        ; Parse filename into 8.3 format
        ; Source: floppy_fname_page (null-terminated)
        ; Dest: SECTOR_BUF + fat_dir_offset (8 bytes name + 3 bytes ext)
        ldx #0                  ; Source index into floppy_fname_page
        ldy fat_dir_offset      ; Dest index into SECTOR_BUF
        lda #0
        sta $8E60               ; Name char count (max 8)
        sta $8E61               ; Extension flag (1 = after dot)

        ; Fill name portion (8 bytes) with spaces first
        pha
        ldy fat_dir_offset
        lda #$20
        ldx #11
_fcd_fill_spaces:
        sta SECTOR_BUF,y
        iny
        dex
        bne _fcd_fill_spaces
        pla

        ldx #0                  ; Source index
        ldy fat_dir_offset      ; Dest index
_fcd_name_loop:
        lda floppy_fname_page,x
        beq _fcd_name_done      ; Null terminator
        cmp #'.'
        beq _fcd_dot
        ; Uppercase conversion
        cmp #'a'
        bcc _fcd_store
        cmp #'z'+1
        bcs _fcd_store
        and #$DF                ; To uppercase
_fcd_store:
        lda $8E61               ; In extension?
        bne _fcd_store_ext
        ; Name portion (max 8 chars)
        lda $8E60
        cmp #8
        bcs _fcd_skip_char      ; Already 8 chars, skip
        lda floppy_fname_page,x
        cmp #'a'
        bcc +
        cmp #'z'+1
        bcs +
        and #$DF
+       sta SECTOR_BUF,y
        iny
        inc $8E60
_fcd_skip_char:
        inx
        bra _fcd_name_loop

_fcd_store_ext:
        ; Extension portion (max 3 chars)
        lda floppy_fname_page,x
        cmp #'a'
        bcc +
        cmp #'z'+1
        bcs +
        and #$DF
+       sta SECTOR_BUF,y
        iny
        inx
        bra _fcd_name_loop

_fcd_dot:
        ; Switch to extension at offset +8
        lda #1
        sta $8E61
        lda fat_dir_offset
        clc
        adc #8
        tay                     ; Y = start of extension field
        inx
        bra _fcd_name_loop

_fcd_name_done:
        ; Set attribute byte: offset +$0B = $20 (archive)
        ldy fat_dir_offset
        lda #$20
        sta SECTOR_BUF+$0B,y

        ; Set first cluster low word: offset +$1A (2 bytes)
        lda fat_file_cluster
        sta SECTOR_BUF+$1A,y
        lda fat_file_cluster+1
        sta SECTOR_BUF+$1B,y

        ; Set first cluster high word: offset +$14 (2 bytes)
        lda fat_file_cluster+2
        sta SECTOR_BUF+$14,y
        lda fat_file_cluster+3
        sta SECTOR_BUF+$15,y

        ; Set file size: offset +$1C (4 bytes)
        lda fat_file_size
        sta SECTOR_BUF+$1C,y
        lda fat_file_size+1
        sta SECTOR_BUF+$1D,y
        lda fat_file_size+2
        sta SECTOR_BUF+$1E,y
        lda fat_file_size+3
        sta SECTOR_BUF+$1F,y

        ; Copy SECTOR_BUF back to SD buffer and write
        lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr chip_to_sd_buf

        lda fat_dir_sector
        sta fat_tmp0
        lda fat_dir_sector+1
        sta fat_tmp0+1
        lda fat_dir_sector+2
        sta fat_tmp0+2
        lda fat_dir_sector+3
        sta fat_tmp0+3
        jsr sd_write_sector
        rts

; ============================================================================
; fat_save_floppy — Main entry point: save floppy image to SD card
; ============================================================================
; Input:  A = drive number (0=A, 1=B)
;         floppy_fname_page = filename (null-terminated)
;         Caller should have already called hyppo_rmfile to delete old file
;
; Output: carry set = success, carry clear = failure
;
fat_save_floppy:
        ; Save drive number and set up attic source
        cmp #1
        beq _fsf_drive_b
        lda #$10                ; Drive A attic bank
        sta fat_attic_bank
        ; Compute file size from geometry: cyls × heads × spt × 512
        lda floppy_a_cyls
        sta $8E60
        lda floppy_a_heads
        sta $8E61
        lda floppy_a_spt
        sta $8E62
        bra _fsf_setup
_fsf_drive_b:
        lda #$20                ; Drive B attic bank
        sta fat_attic_bank
        lda floppy_b_cyls
        sta $8E60
        lda floppy_b_heads
        sta $8E61
        lda floppy_b_spt
        sta $8E62

_fsf_setup:
        ; Reset attic read pointer to start
        lda #0
        sta fat_attic_lo
        sta fat_attic_hi

        ; Compute total sectors = cyls × heads × spt
        ; Use hardware multiplier at $D770
        lda $8E60               ; Cylinders
        sta $D770
        lda #0
        sta $D771
        lda $8E61               ; Heads
        sta $D774
        lda #0
        sta $D775
        ; Result = cyls × heads (16-bit)
        lda $D778
        sta $D770
        lda $D779
        sta $D771
        lda $8E62               ; SPT
        sta $D774
        lda #0
        sta $D775
        ; Result = total sectors (16-bit at $D778/$D779)
        ; File size = total_sectors × 512 (shift left 9)
        ; total_sectors in D778/D779, shift left 9:
        ; byte 0 = 0
        ; byte 1 = total_lo << 1
        ; byte 2 = (total_hi << 1) | (total_lo >> 7)
        ; byte 3 = total_hi >> 7
        lda #0
        sta fat_file_size
        lda $D778               ; Total sectors low
        asl
        sta fat_file_size+1
        lda $D779               ; Total sectors high
        rol
        sta fat_file_size+2
        lda #0
        rol
        sta fat_file_size+3

        ; Save total sectors for the write loop
        lda $D778
        sta fat_remaining
        lda $D779
        sta fat_remaining+1
        lda #0
        sta fat_remaining+2
        sta fat_remaining+3

        ; Step 1: Open filesystem
        jsr fat_open_filesystem
        bcc _fsf_fail

        ; Step 2: Find empty directory entry
        jsr fat_find_empty_direntry
        bcc _fsf_fail

        ; Step 3: Find first free cluster and allocate it
        jsr fat_find_free_cluster
        bcc _fsf_fail
        ; fat_tmp0 = first free cluster
        lda fat_tmp0
        sta fat_file_cluster
        sta fat_cur_cluster
        lda fat_tmp0+1
        sta fat_file_cluster+1
        sta fat_cur_cluster+1
        lda fat_tmp0+2
        sta fat_file_cluster+2
        sta fat_cur_cluster+2
        lda fat_tmp0+3
        sta fat_file_cluster+3
        sta fat_cur_cluster+3
        jsr fat_allocate_cluster

        ; Step 4: Create directory entry
        jsr fat_create_direntry

        ; Step 5: Write data sectors
        lda #0
        sta fat_sector_in_cluster

_fsf_write_loop:
        ; Check if any sectors remain
        lda fat_remaining
        ora fat_remaining+1
        ora fat_remaining+2
        ora fat_remaining+3
        beq _fsf_write_done

        ; Check if we need a new cluster
        lda fat_sector_in_cluster
        cmp fat_sectors_per_cluster
        bcc _fsf_write_sector

        ; Allocate new cluster and chain from current
        ; Save current cluster
        lda fat_cur_cluster
        pha
        lda fat_cur_cluster+1
        pha
        lda fat_cur_cluster+2
        pha
        lda fat_cur_cluster+3
        pha

        ; Find next free cluster
        jsr fat_find_free_cluster
        bcc _fsf_fail_pop4

        ; New cluster in fat_tmp0 — save as new current
        lda fat_tmp0
        sta fat_cur_cluster
        lda fat_tmp0+1
        sta fat_cur_cluster+1
        lda fat_tmp0+2
        sta fat_cur_cluster+2
        lda fat_tmp0+3
        sta fat_cur_cluster+3

        ; Allocate new cluster (mark end-of-chain)
        jsr fat_allocate_cluster

        ; Chain old cluster → new cluster
        ; fat_tmp0 = old cluster (from stack)
        ; fat_tmp1 = new cluster
        lda fat_cur_cluster
        sta fat_tmp1
        lda fat_cur_cluster+1
        sta fat_tmp1+1
        lda fat_cur_cluster+2
        sta fat_tmp1+2
        lda fat_cur_cluster+3
        sta fat_tmp1+3

        pla
        sta fat_tmp0+3
        pla
        sta fat_tmp0+2
        pla
        sta fat_tmp0+1
        pla
        sta fat_tmp0
        jsr fat_chain_cluster

        lda #0
        sta fat_sector_in_cluster

_fsf_write_sector:
        ; Compute SD sector: cluster_to_sector(cur_cluster) + sector_in_cluster
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_cluster_to_sector
        ; Add sector_in_cluster
        clc
        lda fat_tmp0
        adc fat_sector_in_cluster
        sta fat_tmp0
        lda fat_tmp0+1
        adc #0
        sta fat_tmp0+1
        lda fat_tmp0+2
        adc #0
        sta fat_tmp0+2
        ; fat_tmp0 = target SD sector

        ; DMA 512 bytes from attic to SD buffer
        jsr attic_to_sd_buf

        ; Write SD sector
        jsr sd_write_sector

        ; Advance attic pointer by 512
        clc
        lda fat_attic_lo
        adc #$00
        sta fat_attic_lo
        lda fat_attic_hi
        adc #$02                ; + $200 = 512
        sta fat_attic_hi
        bcc +
        inc fat_attic_bank      ; Carry into next bank (shouldn't happen often)
+
        ; Advance sector in cluster
        inc fat_sector_in_cluster

        ; Decrement remaining sectors
        lda fat_remaining
        bne +
        dec fat_remaining+1
        bne +
        dec fat_remaining+2
+       dec fat_remaining

        jmp _fsf_write_loop

_fsf_write_done:
        ; Success
        sec
        rts

_fsf_fail_pop4:
        pla
        pla
        pla
        pla
_fsf_fail:
        clc
        rts
