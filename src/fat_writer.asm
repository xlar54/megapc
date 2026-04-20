        .cpu    "45gs02"
        * = $3400               ; Assembled to run at $13400 (bank 1)

; ============================================================================
; Jump table — fixed entry points (addresses never change)
; ============================================================================
        jmp fat_save_floppy     ; $3400: Save floppy image to SD card

; ============================================================================
; Parameter block — caller copies data here before calling via JSRFAR
; ============================================================================
; $3403:
fw_drive_num    .byte 0         ; 0=A, 1=B
fw_cylinders    .byte 0         ; Drive geometry
fw_heads        .byte 0
fw_spt          .byte 0
fw_filename     .fill 64, 0    ; Null-terminated filename (8.3 or long)
; $3447 — next available

; ============================================================================
; fat_writer.asm — FAT32 file writer for saving floppy images to SD card
; ============================================================================
;
; Compiled separately and loaded to bank 1 at $13400 during startup.
; Called from disk.asm when saving floppy images to SD card.
;
; Saves a floppy disk image from attic RAM back to the SD card FAT32
; filesystem. Uses raw SD card sector reads/writes via $D680/$D681.
;
; Flow:
;   1. Caller deletes old file via Hyppo rmfile (before JSRFAR call)
;   2. fat_open_filesystem — parse MBR + BPB
;   3. fat_find_empty_direntry — find slot in root directory
;   4. fat_find_free_cluster — allocate clusters
;   5. fat_create_direntry — write 8.3 directory entry
;   6. Write data sectors from attic to SD card
;   7. fat_update_direntry_size — patch file size
;
; SD card hardware interface:
;   $D680     — SD command register
;              $02 = read sector, $03 = write sector, $57 = write gate
;              $C0 = select SD slot 0 (internal), $C1 = select slot 1 (external)
;              Core auto-selects external if present at boot — may not need manual select
;   $D681-684 — SD sector number (32-bit, little-endian)
;   $D689     — bit 7: map SD buffer instead of floppy buffer
;   $FFD6E00  — 512-byte SD sector buffer (28-bit: MB=$FF, bank=$0D, addr=$6E00)
;
; IMPORTANT: The SD buffer is in I/O space at $FFD6E00, NOT chip RAM at $00D6E00.
; CPU access requires temp_ptr+3=$FF. DMA requires MB=$FF for source or dest.
;
; All filenames must be 8.3 format (no long filename support).
; All 32-bit values are little-endian.
; Uses SECTOR_BUF ($9800) as temp workspace.
; ============================================================================

; --- All shared addresses defined in globals.asm ---
; fat_writer.asm is assembled SEPARATELY (see build.bat) but pulls in the
; same global definitions to guarantee addresses never drift from the
; main emulator binary.
        .include "globals.asm"

; ============================================================================
; sd_wait_ready — Wait for SD card to be ready
; ============================================================================
sd_wait_ready:
        lda $D680
        and #$03
        bne sd_wait_ready
        rts

; ============================================================================
; sd_read_sector — Read SD sector into SD buffer at $FFD6E00
; ============================================================================
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
        lda #$02
        sta $D680
        jsr sd_wait_ready
        lda $D680
        and #$40
        bne _sdr_fail
        sec
        rts
_sdr_fail:
        clc
        rts

; ============================================================================
; sd_write_sector — Write SD buffer at $FFD6E00 to SD sector
; ============================================================================
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
        lda #$57
        sta $D680
        lda #$03
        sta $D680
        jsr sd_wait_ready
        lda $D680
        and #$40
        bne _sdw_fail
        sec
        rts
_sdw_fail:
        clc
        rts

; ============================================================================
; sd_buf_to_chip — Copy 512 bytes from SD buffer to chip RAM
; ============================================================================
sd_buf_to_chip:
        lda fat_tmp1
        sta _sbtc_dst
        lda fat_tmp1+1
        sta _sbtc_dst+1
        lda fat_tmp1+2
        sta _sbtc_dst_bank
        lda #$00
        sta $D707
        .byte $80, $FF
        .byte $81, $00
        .byte $00
        .byte $00
        .word $0200
        .word $6E00
        .byte $0D
_sbtc_dst:
        .word $0000
_sbtc_dst_bank:
        .byte $00
        .byte $00, $00, $00
        rts

; ============================================================================
; chip_to_sd_buf — Copy 512 bytes from chip RAM to SD buffer
; ============================================================================
chip_to_sd_buf:
        lda fat_tmp1
        sta _ctsb_src
        lda fat_tmp1+1
        sta _ctsb_src+1
        lda fat_tmp1+2
        sta _ctsb_src_bank
        lda #$00
        sta $D707
        .byte $80, $00
        .byte $81, $FF
        .byte $00
        .byte $00
        .word $0200
_ctsb_src:
        .word $0000
_ctsb_src_bank:
        .byte $00
        .word $6E00
        .byte $0D
        .byte $00, $00, $00
        rts

; ============================================================================
; attic_to_sd_buf — DMA 512 bytes from attic to SD buffer
; ============================================================================
attic_to_sd_buf:
        lda fat_attic_lo
        sta _atsb_src
        lda fat_attic_hi
        sta _atsb_src+1
        lda fat_attic_bank
        and #$0F
        sta _atsb_src_bank
        lda fat_attic_bank
        lsr
        lsr
        lsr
        lsr
        ora #$80
        sta _atsb_src_mb
        lda #$00
        sta $D707
        .byte $80
_atsb_src_mb:
        .byte $80
        .byte $81, $FF
        .byte $00
        .byte $00
        .word $0200
_atsb_src:
        .word $0000
_atsb_src_bank:
        .byte $00
        .word $6E00
        .byte $0D
        .byte $00, $00, $00
        rts

; ============================================================================
; fat_open_filesystem — Parse MBR and FAT32 BPB
; ============================================================================
fat_open_filesystem:
        lda $D689
        ora #$80
        sta $D689
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
        jsr sd_read_sector
        bcs +
        rts
+       lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #$00
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip
        ldx #0
_fof_scan:
        txa
        asl
        asl
        asl
        asl
        clc
        adc #<(SECTOR_BUF+$1BE)
        sta temp_ptr
        lda #>(SECTOR_BUF+$1BE)
        adc #0
        sta temp_ptr+1
        lda #0
        sta temp_ptr+2
        sta temp_ptr+3
        ldy #4
        lda (temp_ptr),y
        cmp #$0C
        beq _fof_found
        cmp #$0B
        beq _fof_found
        inx
        cpx #4
        bne _fof_scan
        clc
        rts
_fof_found:
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
        lda fat_partition_start
        sta fat_tmp0
        lda fat_partition_start+1
        sta fat_tmp0+1
        lda fat_partition_start+2
        sta fat_tmp0+2
        lda fat_partition_start+3
        sta fat_tmp0+3
        jsr sd_read_sector
        bcs +
        rts
+       lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #$00
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip
        lda SECTOR_BUF+$0D
        sta fat_sectors_per_cluster
        lda SECTOR_BUF+$0E
        sta fat_reserved_sectors
        lda SECTOR_BUF+$0F
        sta fat_reserved_sectors+1
        lda SECTOR_BUF+$24
        sta fat_sectors_per_fat
        lda SECTOR_BUF+$25
        sta fat_sectors_per_fat+1
        lda SECTOR_BUF+$26
        sta fat_sectors_per_fat+2
        lda SECTOR_BUF+$27
        sta fat_sectors_per_fat+3
        lda SECTOR_BUF+$2C
        sta fat_first_cluster
        lda SECTOR_BUF+$2D
        sta fat_first_cluster+1
        lda SECTOR_BUF+$2E
        sta fat_first_cluster+2
        lda SECTOR_BUF+$2F
        sta fat_first_cluster+3
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
        lda SECTOR_BUF+$20
        sta fat_max_cluster
        lda SECTOR_BUF+$21
        sta fat_max_cluster+1
        lda SECTOR_BUF+$22
        sta fat_max_cluster+2
        lda SECTOR_BUF+$23
        sta fat_max_cluster+3
        sec
        lda fat_max_cluster
        sbc fat_data_sector
        sta fat_max_cluster
        lda fat_max_cluster+1
        sbc fat_data_sector+1
        sta fat_max_cluster+1
        lda fat_max_cluster+2
        sbc fat_data_sector+2
        sta fat_max_cluster+2
        lda fat_max_cluster+3
        sbc fat_data_sector+3
        sta fat_max_cluster+3
        clc
        lda fat_max_cluster
        adc fat_partition_start
        sta fat_max_cluster
        lda fat_max_cluster+1
        adc fat_partition_start+1
        sta fat_max_cluster+1
        lda fat_max_cluster+2
        adc fat_partition_start+2
        sta fat_max_cluster+2
        lda fat_max_cluster+3
        adc fat_partition_start+3
        sta fat_max_cluster+3
        lda fat_sectors_per_cluster
_fof_div_spc:
        lsr
        bcs _fof_div_done
        lsr fat_max_cluster+3
        ror fat_max_cluster+2
        ror fat_max_cluster+1
        ror fat_max_cluster
        bra _fof_div_spc
_fof_div_done:
        clc
        lda fat_max_cluster
        adc #1
        sta fat_max_cluster
        lda fat_max_cluster+1
        adc #0
        sta fat_max_cluster+1
        lda fat_max_cluster+2
        adc #0
        sta fat_max_cluster+2
        lda fat_max_cluster+3
        adc #0
        sta fat_max_cluster+3
        sec
        rts

; ============================================================================
; fat_cluster_to_sector
; ============================================================================
fat_cluster_to_sector:
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
        lda fat_sectors_per_cluster
        lsr
        bcc _fcts_shift
        bra _fcts_add
_fcts_shift:
        asl fat_tmp0
        rol fat_tmp0+1
        rol fat_tmp0+2
        rol fat_tmp0+3
        lsr
        bcs _fcts_add
        bra _fcts_shift
_fcts_add:
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
; fat_find_free_cluster
; ============================================================================
fat_find_free_cluster:
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
_fffc_next_sector:
        clc
        lda fat_fat1_sector
        adc fat_tmp0
        sta fat_tmp1
        lda fat_fat1_sector+1
        adc fat_tmp0+1
        sta fat_tmp1+1
        lda fat_fat1_sector+2
        adc fat_tmp0+2
        sta fat_tmp1+2
        lda fat_fat1_sector+3
        adc fat_tmp0+3
        sta fat_tmp1+3
        lda fat_tmp0
        pha
        lda fat_tmp0+1
        pha
        lda fat_tmp0+2
        pha
        lda fat_tmp0+3
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
        bcs +
        pla
        pla
        pla
        pla
        clc
        rts
+       lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip
        pla
        sta fat_tmp0+3
        pla
        sta fat_tmp0+2
        pla
        sta fat_tmp0+1
        pla
        sta fat_tmp0
        lda fat_tmp0
        ora fat_tmp0+1
        ora fat_tmp0+2
        ora fat_tmp0+3
        bne +
        ldy #8
        bra _fffc_scan
+       ldy #0
_fffc_scan:
        lda SECTOR_BUF,y
        ora SECTOR_BUF+1,y
        ora SECTOR_BUF+2,y
        ora SECTOR_BUF+3,y
        beq _fffc_found
        tya
        clc
        adc #4
        tay
        cpy #0
        beq _fffc_high_half
        bra _fffc_scan
_fffc_high_half:
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
        sty fat_tmp1
        lda #1
        sta fat_tmp1+1
        bra _fffc_calc_cluster
_fffc_found:
        sty fat_tmp1
        lda #0
        sta fat_tmp1+1
_fffc_calc_cluster:
        ldx #7
_fffc_shl:
        asl fat_tmp0
        rol fat_tmp0+1
        rol fat_tmp0+2
        rol fat_tmp0+3
        dex
        bne _fffc_shl
        lda fat_tmp1
        lsr
        lsr
        clc
        adc fat_tmp0
        sta fat_tmp0
        lda fat_tmp0+1
        adc #0
        sta fat_tmp0+1
        lda fat_tmp0+2
        adc #0
        sta fat_tmp0+2
        lda fat_tmp0+3
        adc #0
        sta fat_tmp0+3
        lda fat_tmp1+1
        beq _fffc_done
        clc
        lda fat_tmp0
        adc #64
        sta fat_tmp0
        lda fat_tmp0+1
        adc #0
        sta fat_tmp0+1
        lda fat_tmp0+2
        adc #0
        sta fat_tmp0+2
        lda fat_tmp0+3
        adc #0
        sta fat_tmp0+3
_fffc_done:
        lda fat_tmp0+3
        cmp fat_max_cluster+3
        bcc _fffc_valid
        bne _fffc_full
        lda fat_tmp0+2
        cmp fat_max_cluster+2
        bcc _fffc_valid
        bne _fffc_full
        lda fat_tmp0+1
        cmp fat_max_cluster+1
        bcc _fffc_valid
        bne _fffc_full
        lda fat_tmp0
        cmp fat_max_cluster
        bcc _fffc_valid
        beq _fffc_valid
_fffc_full:
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
        clc
        rts
_fffc_valid:
        sec
        rts
_fffc_not_in_sector:
        inc fat_tmp0
        bne +
        inc fat_tmp0+1
        bne +
        inc fat_tmp0+2
        bne +
        inc fat_tmp0+3
+       lda fat_tmp0+3
        cmp fat_sectors_per_fat+3
        bne _fffc_next_sector
        lda fat_tmp0+2
        cmp fat_sectors_per_fat+2
        bne _fffc_next_sector
        lda fat_tmp0+1
        cmp fat_sectors_per_fat+1
        bne _fffc_next_sector
        lda fat_tmp0
        cmp fat_sectors_per_fat
        bne _fffc_next_sector
        lda #0
        sta fat_tmp0
        sta fat_tmp0+1
        sta fat_tmp0+2
        sta fat_tmp0+3
        clc
        rts

; ============================================================================
; fat_set_cluster_value
; ============================================================================
fat_set_cluster_value:
        lda fat_tmp0
        and #$7F
        asl
        asl
        sta fat_fat_offset
        lda #0
        rol
        sta fat_fat_offset+1
        lda fat_tmp0
        sta fat_fat_sec_idx
        lda fat_tmp0+1
        sta fat_fat_sec_idx+1
        lda fat_tmp0+2
        sta fat_fat_sec_idx+2
        lda fat_tmp0+3
        sta fat_fat_sec_idx+3
        ldx #7
_fscv_shr:
        lsr fat_fat_sec_idx+3
        ror fat_fat_sec_idx+2
        ror fat_fat_sec_idx+1
        ror fat_fat_sec_idx
        dex
        bne _fscv_shr
        clc
        lda fat_fat1_sector
        adc fat_fat_sec_idx
        sta fat_tmp0
        lda fat_fat1_sector+1
        adc fat_fat_sec_idx+1
        sta fat_tmp0+1
        lda fat_fat1_sector+2
        adc fat_fat_sec_idx+2
        sta fat_tmp0+2
        lda fat_fat1_sector+3
        adc fat_fat_sec_idx+3
        sta fat_tmp0+3
        lda fat_tmp0
        sta fat_fat1_abs
        lda fat_tmp0+1
        sta fat_fat1_abs+1
        lda fat_tmp0+2
        sta fat_fat1_abs+2
        lda fat_tmp0+3
        sta fat_fat1_abs+3
        jsr sd_read_sector
        bcc _fscv_fail
        clc
        lda #$00
        adc fat_fat_offset
        sta temp_ptr
        lda #$6E
        adc fat_fat_offset+1
        sta temp_ptr+1
        lda #$0D
        adc #0
        sta temp_ptr+2
        lda #$FF
        sta temp_ptr+3
        lda fat_tmp1
        ldz #0
        sta [temp_ptr],z
        lda fat_tmp1+1
        ldz #1
        sta [temp_ptr],z
        lda fat_tmp1+2
        ldz #2
        sta [temp_ptr],z
        ldz #3
        lda [temp_ptr],z
        and #$F0
        sta fat_fat_offset
        lda fat_tmp1+3
        and #$0F
        ora fat_fat_offset
        sta [temp_ptr],z
        lda fat_fat1_abs
        sta fat_tmp0
        lda fat_fat1_abs+1
        sta fat_tmp0+1
        lda fat_fat1_abs+2
        sta fat_tmp0+2
        lda fat_fat1_abs+3
        sta fat_tmp0+3
        jsr sd_write_sector
        bcc _fscv_fail
        clc
        lda fat_fat1_abs
        adc fat_sectors_per_fat
        sta fat_tmp0
        lda fat_fat1_abs+1
        adc fat_sectors_per_fat+1
        sta fat_tmp0+1
        lda fat_fat1_abs+2
        adc fat_sectors_per_fat+2
        sta fat_tmp0+2
        lda fat_fat1_abs+3
        adc fat_sectors_per_fat+3
        sta fat_tmp0+3
        jsr sd_write_sector
        rts
_fscv_fail:
        clc
        rts

; ============================================================================
; fat_allocate_cluster / fat_chain_cluster
; ============================================================================
fat_allocate_cluster:
        lda #$F8
        sta fat_tmp1
        lda #$FF
        sta fat_tmp1+1
        sta fat_tmp1+2
        lda #$0F
        sta fat_tmp1+3
        jmp fat_set_cluster_value

fat_chain_cluster:
        jmp fat_set_cluster_value

; ============================================================================
; fat_find_empty_direntry
; ============================================================================
fat_find_empty_direntry:
        lda fat_first_cluster
        sta fat_cur_cluster
        lda fat_first_cluster+1
        sta fat_cur_cluster+1
        lda fat_first_cluster+2
        sta fat_cur_cluster+2
        lda fat_first_cluster+3
        sta fat_cur_cluster+3
_ffed_next_cluster:
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_cluster_to_sector
        lda fat_tmp0
        sta fat_dir_save_a
        lda fat_tmp0+1
        sta fat_dir_save_a+1
        lda fat_tmp0+2
        sta fat_cluster_base
        lda fat_tmp0+3
        sta fat_cluster_base+1
        lda #0
        sta fat_sector_in_cluster
_ffed_next_sector:
        clc
        lda fat_dir_save_a
        adc fat_sector_in_cluster
        sta fat_tmp0
        lda fat_dir_save_a+1
        adc #0
        sta fat_tmp0+1
        lda fat_cluster_base
        adc #0
        sta fat_tmp0+2
        lda fat_cluster_base+1
        adc #0
        sta fat_tmp0+3
        lda fat_tmp0
        sta fat_dir_sector
        lda fat_tmp0+1
        sta fat_dir_sector+1
        lda fat_tmp0+2
        sta fat_dir_sector+2
        lda fat_tmp0+3
        sta fat_dir_sector+3
        jsr sd_read_sector
        bcs +
        clc
        rts
+       lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip
        ldy #0
_ffed_scan_entry:
        lda SECTOR_BUF,y
        beq _ffed_found
        cmp #$E5
        beq _ffed_found
        tya
        clc
        adc #32
        tay
        beq _ffed_scan_high
        bra _ffed_scan_entry
_ffed_scan_high:
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
        beq _ffed_sector_done
        bra _ffed_scan_entry2
_ffed_found_high:
        tya
        sta fat_dir_offset
        lda #1
        sta fat_dir_offset+1
        sec
        rts
_ffed_found:
        sty fat_dir_offset
        lda #0
        sta fat_dir_offset+1
        sec
        rts
_ffed_sector_done:
        inc fat_sector_in_cluster
        lda fat_sector_in_cluster
        cmp fat_sectors_per_cluster
        bcc _ffed_next_sector
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_read_cluster_value
        bcs +
        clc
        rts
+       lda fat_tmp0+3
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
        bcs _ffed_dir_full
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
        clc
        rts

; ============================================================================
; fat_read_cluster_value
; ============================================================================
fat_read_cluster_value:
        lda fat_tmp0
        and #$7F
        asl
        asl
        sta fat_fat_offset
        lda #0
        rol
        sta fat_fat_offset+1
        lda fat_tmp0
        sta fat_fat_sec_idx
        lda fat_tmp0+1
        sta fat_fat_sec_idx+1
        lda fat_tmp0+2
        sta fat_fat_sec_idx+2
        lda fat_tmp0+3
        sta fat_fat_sec_idx+3
        ldx #7
_frcv_shr:
        lsr fat_fat_sec_idx+3
        ror fat_fat_sec_idx+2
        ror fat_fat_sec_idx+1
        ror fat_fat_sec_idx
        dex
        bne _frcv_shr
        clc
        lda fat_fat1_sector
        adc fat_fat_sec_idx
        sta fat_tmp0
        lda fat_fat1_sector+1
        adc fat_fat_sec_idx+1
        sta fat_tmp0+1
        lda fat_fat1_sector+2
        adc fat_fat_sec_idx+2
        sta fat_tmp0+2
        lda fat_fat1_sector+3
        adc fat_fat_sec_idx+3
        sta fat_tmp0+3
        jsr sd_read_sector
        bcc _frcv_fail
        clc
        lda #$00
        adc fat_fat_offset
        sta temp_ptr
        lda #$6E
        adc fat_fat_offset+1
        sta temp_ptr+1
        lda #$0D
        adc #0
        sta temp_ptr+2
        lda #$FF
        sta temp_ptr+3
        ldz #0
        lda [temp_ptr],z
        sta fat_tmp0
        ldz #1
        lda [temp_ptr],z
        sta fat_tmp0+1
        ldz #2
        lda [temp_ptr],z
        sta fat_tmp0+2
        ldz #3
        lda [temp_ptr],z
        and #$0F
        sta fat_tmp0+3
        sec
        rts
_frcv_fail:
        clc
        rts

; ============================================================================
; fat_create_direntry
; ============================================================================
fat_create_direntry:
        lda fat_dir_sector
        sta fat_tmp0
        lda fat_dir_sector+1
        sta fat_tmp0+1
        lda fat_dir_sector+2
        sta fat_tmp0+2
        lda fat_dir_sector+3
        sta fat_tmp0+3
        jsr sd_read_sector
        bcs +
        rts
+       lda #<SECTOR_BUF
        sta fat_tmp1
        lda #>SECTOR_BUF
        sta fat_tmp1+1
        lda #0
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr sd_buf_to_chip
        clc
        lda #<SECTOR_BUF
        adc fat_dir_offset
        sta temp_ptr
        lda #>SECTOR_BUF
        adc fat_dir_offset+1
        sta temp_ptr+1
        lda #0
        sta temp_ptr+2
        sta temp_ptr+3
        ldz #0
        ldx #32
_fcd_clear:
        lda #0
        sta [temp_ptr],z
        inz
        dex
        bne _fcd_clear
        ldz #0
        ldx #11
_fcd_fill_spaces:
        lda #$20
        sta [temp_ptr],z
        inz
        dex
        bne _fcd_fill_spaces
        ldx #0
        lda #0
        sta fat_name_count
        sta fat_ext_flag
        sta fat_ext_count
        ldz #0
_fcd_name_loop:
        lda fw_filename,x
        beq _fcd_name_done
        cmp #'.'
        beq _fcd_dot
        cmp #'a'
        bcc _fcd_no_upper
        cmp #'z'+1
        bcs _fcd_no_upper
        and #$DF
_fcd_no_upper:
        pha
        lda fat_ext_flag
        bne _fcd_store_ext
        lda fat_name_count
        cmp #8
        bcs _fcd_skip_char
        pla
        sta [temp_ptr],z
        inz
        inc fat_name_count
        inx
        bra _fcd_name_loop
_fcd_skip_char:
        pla
        inx
        bra _fcd_name_loop
_fcd_store_ext:
        lda fat_ext_count
        cmp #3
        bcs _fcd_skip_ext
        pla
        sta [temp_ptr],z
        inz
        inc fat_ext_count
        inx
        bra _fcd_name_loop
_fcd_skip_ext:
        pla
        inx
        bra _fcd_name_loop
_fcd_dot:
        lda #1
        sta fat_ext_flag
        lda #0
        sta fat_ext_count
        ldz #8
        inx
        bra _fcd_name_loop
_fcd_name_done:
        lda #$20
        ldz #$0B
        sta [temp_ptr],z
        lda fat_file_cluster
        ldz #$1A
        sta [temp_ptr],z
        lda fat_file_cluster+1
        ldz #$1B
        sta [temp_ptr],z
        lda fat_file_cluster+2
        ldz #$14
        sta [temp_ptr],z
        lda fat_file_cluster+3
        ldz #$15
        sta [temp_ptr],z
        lda #0
        ldz #$1C
        sta [temp_ptr],z
        ldz #$1D
        sta [temp_ptr],z
        ldz #$1E
        sta [temp_ptr],z
        ldz #$1F
        sta [temp_ptr],z
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
; fat_save_floppy — Main entry point
; ============================================================================
fat_save_floppy:
        ; Reset SD card controller (Hyppo traps may leave it in busy state)
        lda #$C1
        sta $D680
        jsr sd_wait_ready

        ; Bank passed from caller via fat_save_bank ($8F28)
        lda fat_save_bank
        sta fat_attic_bank
_fsf_copy_geom:
        lda fw_cylinders
        sta fat_name_count
        lda fw_heads
        sta fat_ext_flag
        lda fw_spt
        sta fat_ext_count

_fsf_setup:
        lda #0
        sta fat_attic_lo
        sta fat_attic_hi
        lda fat_name_count
        sta $D770
        lda #0
        sta $D771
        lda fat_ext_flag
        sta $D774
        lda #0
        sta $D775
        lda $D778
        sta $D770
        lda $D779
        sta $D771
        lda fat_ext_count
        sta $D774
        lda #0
        sta $D775
        lda #0
        sta fat_file_size
        lda $D778
        asl
        sta fat_file_size+1
        lda $D779
        rol
        sta fat_file_size+2
        lda #0
        rol
        sta fat_file_size+3
        lda $D778
        sta fat_remaining
        lda $D779
        sta fat_remaining+1
        lda #0
        sta fat_remaining+2
        sta fat_remaining+3
        sta fat_direntry_created
        sta fat_chain_allocated

        jsr fat_open_filesystem
        bcc _fsf_fail
        jsr fat_find_empty_direntry
        bcc _fsf_fail
        jsr fat_find_free_cluster
        bcc _fsf_fail
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
        bcc _fsf_fail
        lda #1
        sta fat_chain_allocated
        jsr fat_create_direntry
        bcc _fsf_fail
        lda #1
        sta fat_direntry_created
        lda #0
        sta fat_sector_in_cluster

_fsf_write_loop:
        lda fat_remaining
        ora fat_remaining+1
        ora fat_remaining+2
        ora fat_remaining+3
        beq _fsf_write_done
        lda fat_sector_in_cluster
        cmp fat_sectors_per_cluster
        bcc _fsf_write_sector
        lda fat_cur_cluster
        pha
        lda fat_cur_cluster+1
        pha
        lda fat_cur_cluster+2
        pha
        lda fat_cur_cluster+3
        pha
        jsr fat_find_free_cluster
        bcc _fsf_fail_pop4
        lda fat_tmp0
        sta fat_cur_cluster
        lda fat_tmp0+1
        sta fat_cur_cluster+1
        lda fat_tmp0+2
        sta fat_cur_cluster+2
        lda fat_tmp0+3
        sta fat_cur_cluster+3
        jsr fat_allocate_cluster
        bcc _fsf_fail_pop4
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
        bcs _fsf_chain_ok
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        lda #0
        sta fat_tmp1
        sta fat_tmp1+1
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr fat_set_cluster_value
        jmp _fsf_fail
_fsf_chain_ok:
        lda #0
        sta fat_sector_in_cluster

_fsf_write_sector:
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_cluster_to_sector
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
        lda fat_tmp0+3
        adc #0
        sta fat_tmp0+3
        jsr attic_to_sd_buf
        jsr sd_write_sector
        bcc _fsf_fail
        clc
        lda fat_attic_lo
        adc #$00
        sta fat_attic_lo
        lda fat_attic_hi
        adc #$02
        sta fat_attic_hi
        bcc +
        inc fat_attic_bank
+       inc fat_sector_in_cluster
        sec
        lda fat_remaining
        sbc #1
        sta fat_remaining
        lda fat_remaining+1
        sbc #0
        sta fat_remaining+1
        lda fat_remaining+2
        sbc #0
        sta fat_remaining+2
        lda fat_remaining+3
        sbc #0
        sta fat_remaining+3
        jmp _fsf_write_loop

_fsf_write_done:
        jsr fat_update_direntry_size
        bcc _fsf_fail
        lda #1
        sta fat_save_drive      ; Signal success via scratch (JSRFAR loses carry)
        rts

_fsf_fail_pop4:
        pla
        pla
        pla
        pla
_fsf_fail:
        lda fat_chain_allocated
        beq _fsf_no_chain
        jsr fat_free_chain
_fsf_no_chain:
        lda fat_direntry_created
        beq _fsf_fail_done
        jsr fat_delete_direntry
_fsf_fail_done:
        lda #0
        sta fat_save_drive      ; Signal failure via scratch (JSRFAR loses carry)
        rts

; ============================================================================
; fat_free_chain
; ============================================================================
fat_free_chain:
        lda fat_file_cluster
        sta fat_cur_cluster
        lda fat_file_cluster+1
        sta fat_cur_cluster+1
        lda fat_file_cluster+2
        sta fat_cur_cluster+2
        lda fat_file_cluster+3
        sta fat_cur_cluster+3
_ffc_loop:
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        jsr fat_read_cluster_value
        bcc _ffc_done
        lda fat_tmp0
        pha
        lda fat_tmp0+1
        pha
        lda fat_tmp0+2
        pha
        lda fat_tmp0+3
        pha
        lda fat_cur_cluster
        sta fat_tmp0
        lda fat_cur_cluster+1
        sta fat_tmp0+1
        lda fat_cur_cluster+2
        sta fat_tmp0+2
        lda fat_cur_cluster+3
        sta fat_tmp0+3
        lda #0
        sta fat_tmp1
        sta fat_tmp1+1
        sta fat_tmp1+2
        sta fat_tmp1+3
        jsr fat_set_cluster_value
        bcc _ffc_fail_pop4
        pla
        sta fat_cur_cluster+3
        pla
        sta fat_cur_cluster+2
        pla
        sta fat_cur_cluster+1
        pla
        sta fat_cur_cluster
        lda fat_cur_cluster
        ora fat_cur_cluster+1
        ora fat_cur_cluster+2
        ora fat_cur_cluster+3
        beq _ffc_done
        lda fat_cur_cluster+1
        ora fat_cur_cluster+2
        ora fat_cur_cluster+3
        bne _ffc_range_ok
        lda fat_cur_cluster
        cmp #2
        bcc _ffc_done
_ffc_range_ok:
        lda fat_cur_cluster+3
        cmp fat_max_cluster+3
        bcc _ffc_in_range
        bne _ffc_done
        lda fat_cur_cluster+2
        cmp fat_max_cluster+2
        bcc _ffc_in_range
        bne _ffc_done
        lda fat_cur_cluster+1
        cmp fat_max_cluster+1
        bcc _ffc_in_range
        bne _ffc_done
        lda fat_cur_cluster
        cmp fat_max_cluster
        bcc _ffc_in_range
        beq _ffc_in_range
        bra _ffc_done
_ffc_in_range:
        lda fat_cur_cluster+3
        and #$0F
        cmp #$0F
        bne _ffc_loop
        lda fat_cur_cluster+2
        cmp #$FF
        bne _ffc_loop
        lda fat_cur_cluster+1
        cmp #$FF
        bne _ffc_loop
        lda fat_cur_cluster
        cmp #$F8
        bcc _ffc_loop
_ffc_fail_pop4:
        pla
        pla
        pla
        pla
_ffc_done:
        rts

; ============================================================================
; fat_update_direntry_size
; ============================================================================
fat_update_direntry_size:
        lda fat_dir_sector
        sta fat_tmp0
        lda fat_dir_sector+1
        sta fat_tmp0+1
        lda fat_dir_sector+2
        sta fat_tmp0+2
        lda fat_dir_sector+3
        sta fat_tmp0+3
        jsr sd_read_sector
        bcs +
        rts
+       clc
        lda #$00
        adc fat_dir_offset
        sta temp_ptr
        lda #$6E
        adc fat_dir_offset+1
        sta temp_ptr+1
        lda #$0D
        adc #0
        sta temp_ptr+2
        lda #$FF
        sta temp_ptr+3
        lda fat_file_size
        ldz #$1C
        sta [temp_ptr],z
        lda fat_file_size+1
        ldz #$1D
        sta [temp_ptr],z
        lda fat_file_size+2
        ldz #$1E
        sta [temp_ptr],z
        lda fat_file_size+3
        ldz #$1F
        sta [temp_ptr],z
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
; fat_delete_direntry
; ============================================================================
fat_delete_direntry:
        lda fat_dir_sector
        sta fat_tmp0
        lda fat_dir_sector+1
        sta fat_tmp0+1
        lda fat_dir_sector+2
        sta fat_tmp0+2
        lda fat_dir_sector+3
        sta fat_tmp0+3
        jsr sd_read_sector
        bcs +
        rts
+       clc
        lda #$00
        adc fat_dir_offset
        sta temp_ptr
        lda #$6E
        adc fat_dir_offset+1
        sta temp_ptr+1
        lda #$0D
        adc #0
        sta temp_ptr+2
        lda #$FF
        sta temp_ptr+3
        lda #$E5
        ldz #0
        sta [temp_ptr],z
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
