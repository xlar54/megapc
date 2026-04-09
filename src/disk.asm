; ============================================================================
; disk.asm — Disk I/O (INT 13h)
; ============================================================================
;
; Handles BIOS INT 13h disk services.
; Floppy image is stored in attic RAM at FLOPPY_A_ATTIC ($8100000).
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

; Floppy geometry is now auto-detected — see floppy_a_spt/heads/cyls in disk.asm
FLOPPY_SECTOR_SZ = 512

; Active drive geometry (set by _i13_select_drive for current INT 13h call)
i13_cur_spt     = $8FE0
i13_cur_heads   = $8FE1
i13_cur_cyls    = $8FE2
i13_cur_type    = $8FE3
i13_cur_bank    = $8FE4           ; Attic bank offset ($10=A, $20=B)

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
        cmp #$01
        beq _i13_get_status
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

_i13_get_status:
        ; AH=01: Get status of last operation from BDA 0040:0041
        lda #$41
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda [temp_ptr],z        ; Read last status byte
        sta reg_ah              ; Return in AH
        ; CF=1 if status non-zero, CF=0 if success
        beq +
        lda #1
        sta flag_cf
        rts
+       lda #0
        sta flag_cf
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
        ; DL=0/1 (floppy): return AH=01 (floppy without change-line)
        ; DL>=80 (hard disk): no hard drives
        lda reg_dl
        bmi _i13_gt_harddisk    ; DL >= $80
        cmp #2
        bcc _i13_gt_floppy      ; DL = 0 or 1
        ; Floppy drive >= 2: no drive
        lda #$00
        sta reg_ah
        lda #1
        sta flag_cf
        rts
_i13_gt_floppy:
        ; Drive exists (hardware always present), disk may or may not be inserted
        lda #$01                ; Floppy without change-line
        sta reg_ah
        lda #0
        sta flag_cf
        rts
_i13_gt_harddisk:
        lda #$00                ; No drive
        sta reg_ah
        lda #1
        sta flag_cf             ; CF=1 = no drive
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
        ; DL = drive (0=A, 1=B)
        lda reg_dl
        bmi _i13_hard_disk      ; DL >= $80
        jsr _i13_select_drive
        bcc _i13_gp_nodrive
        ; Return parameters for detected floppy geometry
        lda #$00
        sta reg_ah              ; Status = OK
        lda i13_cur_spt
        sta reg_cl              ; Sectors per track in CL bits 0–5
        lda i13_cur_cyls
        sec
        sbc #1
        sta reg_ch              ; Max cylinder (cyls - 1)
        lda i13_cur_heads
        sec
        sbc #1
        sta reg_dh              ; Max head (heads - 1)
        ; Always report 2 floppy drives
        lda #$02
        sta reg_dl
        lda i13_cur_type
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

_i13_gp_nodrive:
        lda #$80                ; Timeout / not ready
        sta reg_ah
        lda #0
        sta reg_al
        ; Always report 2 floppy drives
        lda #$02
        sta reg_dl
        lda #1
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
        ; Hard disk (DL >= $80): no hard drives present
        ; Return error for all functions
        lda #$01                ; Invalid function / no drive
        sta reg_ah
        lda #0
        sta reg_dl              ; 0 hard drives
        lda #1
        sta flag_cf             ; CF=1 = error
        rts

        ; (_i13_hd_read removed — no hard drives emulated)

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
        jsr _i13_select_drive
        bcc _i13_no_drive       ; Invalid drive or not loaded

        ; Save sector count
        lda reg_al
        sta disk_sect_left      ; sector count (safe from seg_ofs_to_linear)
        sta $8F18               ; save original count for return (safe location)

        ; Save BX — real BIOS preserves BX, caller advances it
        lda reg_bx
        sta $8F19
        lda reg_bx+1
        sta $8F1A

        ; Compute LBA from CHS
        ; LBA = (C × heads + H) × SPT + (S - 1)
        ; C = CH + (CL >> 6 << 8) — for floppy, CL bits 6–7 are always 0
        lda reg_ch              ; Cylinder
        ; C × heads (use hardware multiplier)
        sta $D770
        lda #0
        sta $D771
        lda i13_cur_heads
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
        lda i13_cur_spt
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
        ; Source: FLOPPY_A_ATTIC + byte_offset
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
        adc i13_cur_bank        ; Add attic offset ($10=A, $20=B)
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

        ; Copy 512 bytes from SECTOR_BUF to ES:BX in guest memory
        ; Safe path: re-resolve linear_to_chip for each byte
        ; Handles bank 4, attic, CGA, and boundary crossings correctly
        ldy #0
_i13_copy_loop:
        lda SECTOR_BUF,y
        sta scratch_d
        phy
        jsr linear_to_chip
        lda scratch_d
        ldz #0
        sta [temp_ptr],z
        ; Mark cache dirty if write went to cache buffer
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+
        ; Advance linear address
        inc temp32
        bne +
        inc temp32+1
        bne +
        inc temp32+2
+       ply
        iny
        bne _i13_copy_loop
        ; Second 256 bytes
        ldy #0
_i13_copy_loop2:
        lda SECTOR_BUF+256,y
        sta scratch_d
        phy
        jsr linear_to_chip
        lda scratch_d
        ldz #0
        sta [temp_ptr],z
        lda temp_ptr+2
        bne +
        jsr mark_cache_dirty
+
        inc temp32
        bne +
        inc temp32+1
        bne +
        inc temp32+2
+       ply
        iny
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
        lda $8F19
        sta reg_bx
        lda $8F1A
        sta reg_bx+1
        ; Return success
        lda #$00
        sta reg_ah
        lda $8F18               ; restore original sector count
        sta reg_al              ; AL = sectors actually read
        lda #0
        sta flag_cf
        rts

; ============================================================================
; _i13_write — Write sectors to floppy image (AH=03)
; ============================================================================
; Input: same as _i13_read (AL=count, CH/CL=cyl/sec, DH=head, ES:BX=buffer)
; Reads data from ES:BX, writes to floppy image in attic.
;
_i13_write:
        jsr _i13_select_drive
        bcc _i13_no_drive       ; Invalid drive or not loaded

        ; Save sector count and BX
        lda reg_al
        sta disk_sect_left
        sta $8F18
        lda reg_bx
        sta $8F19
        lda reg_bx+1
        sta $8F1A

        ; Compute LBA from CHS (same as read)
        lda reg_ch
        sta $D770
        lda #0
        sta $D771
        lda i13_cur_heads
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
        lda i13_cur_spt
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

        ; Check if source is in attic ($01-$0E) or bank 4 ($00)
        lda temp32+2
        beq _i13w_bank4_read
        cmp #$0F
        bcs _i13w_bank4_read    ; $F0000+ (ROM) — treat as bank 4 fallback
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
        ; Safe read: re-resolve linear_to_chip for each byte
        ; Handles boundary crossings correctly
        ldy #0
_i13w_rd_loop:
        phy
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        ply
        sta SECTOR_BUF,y
        inc temp32
        bne +
        inc temp32+1
        bne +
        inc temp32+2
+       iny
        bne _i13w_rd_loop
        ldy #0
_i13w_rd_loop2:
        phy
        jsr linear_to_chip
        ldz #0
        lda [temp_ptr],z
        ply
        sta SECTOR_BUF+256,y
        inc temp32
        bne +
        inc temp32+1
        bne +
        inc temp32+2
+       iny
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
        adc i13_cur_bank        ; Attic offset ($10=A, $20=B)
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

        ; Mark drive as dirty (image modified)
        lda i13_cur_bank
        cmp #$20
        beq _i13w_dirty_b
        lda #1
        sta floppy_a_dirty
        bra _i13w_dirty_done
_i13w_dirty_b:
        lda #1
        sta floppy_b_dirty
_i13w_dirty_done:

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
        lda $8F19
        sta reg_bx
        lda $8F1A
        sta reg_bx+1
        lda #$00
        sta reg_ah
        lda $8F18
        sta reg_al
        lda #0
        sta flag_cf
        rts

; ============================================================================
; _i13_select_drive — Set up active drive geometry for INT 13h
; ============================================================================
; Input:  reg_dl = drive number (0=A, 1=B)
; Output: carry set = OK (i13_cur_* filled), carry clear = error
;
_i13_select_drive:
        lda reg_dl
        bmi _i13sd_fail         ; DL >= $80: not a floppy
        beq _i13sd_a
        cmp #1
        beq _i13sd_b
        bra _i13sd_fail         ; DL >= 2: no drive
_i13sd_a:
        lda floppy_a_loaded
        beq _i13sd_fail
        lda floppy_a_spt
        sta i13_cur_spt
        lda floppy_a_heads
        sta i13_cur_heads
        lda floppy_a_cyls
        sta i13_cur_cyls
        lda floppy_a_type
        sta i13_cur_type
        lda #$10
        sta i13_cur_bank
        sec
        rts
_i13sd_b:
        lda floppy_b_loaded
        beq _i13sd_fail
        lda floppy_b_spt
        sta i13_cur_spt
        lda floppy_b_heads
        sta i13_cur_heads
        lda floppy_b_cyls
        sta i13_cur_cyls
        lda floppy_b_type
        sta i13_cur_type
        lda #$20
        sta i13_cur_bank
        sec
        rts
_i13sd_fail:
        clc
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
        lda i13_cur_spt           ; Byte 4: Sectors per track
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

; ============================================================================
; load_floppy_drive — Load floppy disk image to attic RAM via Hyppo
; ============================================================================
; Uses Hyppo trap $2E (setname) and $3E (loadfile_attic).
; Loads fd.img from SD card FAT32 to attic at FLOPPY_A_ATTIC ($8100000).
;
; Hyppo setname: Y = high byte of page-aligned filename, A=$2E, sta $D640, clv
; Hyppo loadfile_attic: X=addr low, Y=addr mid, Z=addr high byte
;   Address is 28-bit: $08ZZYYXX (the $08 prefix means attic)
;   For FLOPPY_A_ATTIC=$8100000: ZZ=$10, YY=$00, XX=$00
;
; Input:  A = drive number (0=A, 1=B)
;         floppy_fname_page = filename (page-aligned, null-terminated)
; Output: carry set = success, carry clear = failure
;         floppy_a_loaded or floppy_b_loaded set on success
; No UI output — caller handles messages.
;
load_floppy_drive:
        pha                     ; Save drive number

        ; Set Hyppo filename from floppy_fname_page
        ldy #>floppy_fname_page
        lda #$2E                ; hyppo_setname
        sta $D640
        clv
        bcc _lfd_fail

        ; Load to attic: Drive A=$8100000 (ZZ=$10), Drive B=$8200000 (ZZ=$20)
        pla                     ; Recover drive number
        pha
        beq _lfd_drive_a
        ldz #$20                ; Drive B
        bra _lfd_load
_lfd_drive_a:
        ldz #$10                ; Drive A
_lfd_load:
        ldy #$00
        ldx #$00
        lda #$3E                ; hyppo_loadfile_attic
        sta $D640
        clv

        bcc _lfd_fail

        ; Success — set loaded flag and detect geometry
        pla                     ; Drive number
        beq _lfd_ok_a
        lda #1
        sta floppy_b_loaded
        lda #0
        sta floppy_b_dirty      ; Fresh image, not dirty
        lda #1
        jsr detect_floppy_geom_drive
        sec
        rts
_lfd_ok_a:
        lda #1
        sta floppy_a_loaded
        lda #0
        sta floppy_a_dirty      ; Fresh image, not dirty
        jsr detect_floppy_geom_drive
        sec
        rts

_lfd_fail:
        pla                     ; Discard drive number
        clc
        rts

; ============================================================================
; save_floppy_drive — Save floppy image from attic back to SD card
; ============================================================================
; Input:  A = drive number (0=A, 1=B)
;         floppy_fname_page = filename (null-terminated)
; Output: carry set = success, carry clear = failure
;
; Flow: Hyppo setname → findfile → rmfile → fat_save_floppy
;
save_floppy_drive:
        ; --- DISABLED: jmp over save logic until tested on real hardware ---
        jmp _sfd_end

        pha                     ; Save drive number

        ; Step 1: Set filename via Hyppo setname
        ldy #>floppy_fname_page
        lda #$2E                ; hyppo_setname
        sta $D640
        clv
        bcc _sfd_fail

        ; Step 2: Find file via Hyppo findfile (required before rmfile)
        lda #$34                ; hyppo_findfile
        sta $D640
        clv
        bcc _sfd_not_found      ; File doesn't exist — skip delete

        ; Step 3: Delete old file via Hyppo rmfile
        lda #$26                ; hyppo_rmfile
        sta $D640
        clv
        ; Ignore rmfile errors — file may already be gone

_sfd_not_found:
        ; Step 4: Create new file and write data via FAT32 writer
        pla                     ; Recover drive number
        pha
;        jsr fat_save_floppy
        bcc _sfd_fail

        ; Success — clear dirty flag
        pla
        beq _sfd_clear_a
        lda #0
        sta floppy_b_dirty
        sec
        rts
_sfd_clear_a:
        lda #0
        sta floppy_a_dirty
        sec
        rts

_sfd_fail:
        pla                     ; Discard drive number
_sfd_end:
        clc
        rts

; ============================================================================
; detect_floppy_geom_drive — Auto-detect floppy geometry from BPB
; ============================================================================
; Reads total sectors from sector 0 of the loaded floppy image.
; Matches against known formats to set geometry variables.
; Must be called after load_floppy_drive and before init_guest_mem.
;
dfg_drive       .byte 0         ; 0=A, 1=B

detect_floppy_geom_drive:
        sta dfg_drive

        ; Set defaults (1.44MB) in case detection fails
        lda #18
        jsr _dfg_store_spt
        lda #2
        jsr _dfg_store_heads
        lda #80
        jsr _dfg_store_cyls
        lda #$04
        jsr _dfg_store_type

        ; Skip if no floppy loaded
        lda dfg_drive
        bne _dfg_check_b
        lda floppy_a_loaded
        beq _dfg_done
        bra _dfg_do_detect
_dfg_check_b:
        lda floppy_b_loaded
        beq _dfg_done

_dfg_do_detect:
        ; DMA 512 bytes from floppy attic to SECTOR_BUF
        ; Drive A = attic bank $10, Drive B = attic bank $20
        lda #$00
        sta dma_src_lo
        sta dma_src_hi
        lda dfg_drive
        bne _dfg_bank_b
        lda #$10                ; Drive A
        bra _dfg_bank_set
_dfg_bank_b:
        lda #$20                ; Drive B
_dfg_bank_set:
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
        sta dma_count_hi        ; 512 bytes
        jsr do_dma_from_attic

        ; Check if BPB is valid: bytes per sector at offset $0B should be $0200
        lda SECTOR_BUF+$0B
        cmp #$00
        bne _dfg_try_media      ; Not $00 in low byte → invalid BPB
        lda SECTOR_BUF+$0C
        cmp #$02
        bne _dfg_try_media      ; Not $02 in high byte → invalid BPB

        ; --- Valid BPB: use total sectors field ---
        lda SECTOR_BUF+$13
        sta scratch_a           ; Total sectors low
        lda SECTOR_BUF+$14
        sta scratch_b           ; Total sectors high
        jmp _dfg_match_sectors

_dfg_try_media:
        ; --- No valid BPB: read FAT media descriptor from sector 1 ---
        ; DMA sector 1 from floppy attic
        lda #$00
        sta dma_src_lo
        lda #$02
        sta dma_src_hi          ; Sector 1 = offset $200
        lda dfg_drive
        bne _dfg_media_b
        lda #$10
        bra _dfg_media_set
_dfg_media_b:
        lda #$20
_dfg_media_set:
        sta dma_src_bank
        lda #<SECTOR_BUF
        sta dma_dst_lo
        lda #>SECTOR_BUF
        sta dma_dst_hi
        lda #$00
        sta dma_dst_bank
        sta dma_count_lo
        lda #$02
        sta dma_count_hi
        jsr do_dma_from_attic

        ; Media descriptor is first byte of FAT
        lda SECTOR_BUF
        ; $FE = 160K, $FF = 320K, $FC = 180K, $FD = 360K
        ; $F9 = 720K or 1.2MB, $F0 = 1.44MB
        cmp #$FF
        beq _dfg_320k
        cmp #$FE
        beq _dfg_160k
        cmp #$FD
        beq _dfg_360k
        cmp #$FC
        beq _dfg_180k
        cmp #$F9
        beq _dfg_720k           ; Could also be 1.2MB, assume 720K
        ; Default: keep 1.44MB
        bra _dfg_print

_dfg_160k:
        lda #8
        jsr _dfg_store_spt
        lda #1
        jsr _dfg_store_heads
        lda #40
        jsr _dfg_store_cyls
        lda #$01
        jsr _dfg_store_type
        bra _dfg_print

_dfg_180k:
        lda #9
        jsr _dfg_store_spt
        lda #1
        jsr _dfg_store_heads
        lda #40
        jsr _dfg_store_cyls
        lda #$01
        jsr _dfg_store_type
        bra _dfg_print

_dfg_320k:
        lda #8
        jsr _dfg_store_spt
        lda #2
        jsr _dfg_store_heads
        lda #40
        jsr _dfg_store_cyls
        lda #$01
        jsr _dfg_store_type
        bra _dfg_print

_dfg_match_sectors:
        ; Match total sectors against known formats
        ; 360K: 720 sectors ($02D0)
        lda scratch_b
        cmp #$02
        bne _dfg_ns_not_360
        lda scratch_a
        cmp #$D0
        bne _dfg_ns_not_360
_dfg_360k:
        lda #9
        jsr _dfg_store_spt
        lda #2
        jsr _dfg_store_heads
        lda #40
        jsr _dfg_store_cyls
        lda #$01
        jsr _dfg_store_type
        bra _dfg_print

_dfg_ns_not_360:
        ; 720K: 1440 sectors ($05A0)
        lda scratch_b
        cmp #$05
        bne _dfg_ns_not_720
        lda scratch_a
        cmp #$A0
        bne _dfg_ns_not_720
_dfg_720k:
        lda #9
        jsr _dfg_store_spt
        lda #2
        jsr _dfg_store_heads
        lda #80
        jsr _dfg_store_cyls
        lda #$03
        jsr _dfg_store_type
        bra _dfg_print

_dfg_ns_not_720:
        ; 1.2MB: 2400 sectors ($0960)
        lda scratch_b
        cmp #$09
        bne _dfg_ns_not_12
        lda scratch_a
        cmp #$60
        bne _dfg_ns_not_12
        lda #15
        jsr _dfg_store_spt
        lda #2
        jsr _dfg_store_heads
        lda #80
        jsr _dfg_store_cyls
        lda #$02
        jsr _dfg_store_type
        bra _dfg_print

_dfg_ns_not_12:
        ; 2880 sectors ($0B40) = 1.44MB (already set as default)
        ; Fall through to print

_dfg_print:
        ; Update DPT at F000:F000 with detected SPT
        lda #$00
        sta temp_ptr
        lda #$F0
        sta temp_ptr+1
        lda #$05
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        jsr _dfg_read_spt
        ldz #4                  ; Byte 4 = sectors per track
        sta [temp_ptr],z

        ; Print detected format
        ldx #0
-       lda _dfg_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        ; Print SPT value
        jsr _dfg_read_spt
        jsr _dfg_print_dec
        lda #'/'
        jsr CHROUT
        ; Print heads
        jsr _dfg_read_heads
        jsr _dfg_print_dec
        lda #'/'
        jsr CHROUT
        ; Print cylinders
        jsr _dfg_read_cyls
        jsr _dfg_print_dec
        lda #' '
        jsr CHROUT
        lda #'('
        jsr CHROUT

        ; Print format name based on type
        jsr _dfg_read_type
        cmp #$01
        beq _dfg_p360
        cmp #$02
        beq _dfg_p12
        cmp #$03
        beq _dfg_p720
        ; Default: 1.44MB
        ldx #0
-       lda _dfg_144,x
        beq _dfg_close
        jsr CHROUT
        inx
        bne -
        bra _dfg_close
_dfg_p360:
        ldx #0
-       lda _dfg_360,x
        beq _dfg_close
        jsr CHROUT
        inx
        bne -
        bra _dfg_close
_dfg_p12:
        ldx #0
-       lda _dfg_12m,x
        beq _dfg_close
        jsr CHROUT
        inx
        bne -
        bra _dfg_close
_dfg_p720:
        ldx #0
-       lda _dfg_720,x
        beq _dfg_close
        jsr CHROUT
        inx
        bne -

_dfg_close:
        lda #')'
        jsr CHROUT
        lda #$0D
        jsr CHROUT
_dfg_done:
        rts

; Print A as 1-3 digit decimal number
_dfg_print_dec:
        ldx #0                  ; Suppress leading zeros
        ; Hundreds
        ldy #0
-       cmp #100
        bcc _dfg_tens
        sbc #100
        iny
        bra -
_dfg_tens:
        pha
        tya
        beq _dfg_skip_h         ; Skip leading zero
        ora #$30
        jsr CHROUT
        ldx #1                  ; No longer suppress
_dfg_skip_h:
        pla
        ; Tens
        ldy #0
-       cmp #10
        bcc _dfg_ones
        sbc #10
        iny
        bra -
_dfg_ones:
        pha
        tya
        bne _dfg_do_tens
        cpx #0
        beq _dfg_skip_t         ; Skip leading zero
_dfg_do_tens:
        ora #$30
        jsr CHROUT
_dfg_skip_t:
        pla
        ; Ones (always print)
        ora #$30
        jsr CHROUT
        rts

; --- Helpers: store/read geometry for current drive ---
_dfg_store_spt:
        ldx dfg_drive
        bne +
        sta floppy_a_spt
        rts
+       sta floppy_b_spt
        rts

_dfg_store_heads:
        ldx dfg_drive
        bne +
        sta floppy_a_heads
        rts
+       sta floppy_b_heads
        rts

_dfg_store_cyls:
        ldx dfg_drive
        bne +
        sta floppy_a_cyls
        rts
+       sta floppy_b_cyls
        rts

_dfg_store_type:
        ldx dfg_drive
        bne +
        sta floppy_a_type
        rts
+       sta floppy_b_type
        rts

_dfg_read_spt:
        ldx dfg_drive
        bne +
        lda floppy_a_spt
        rts
+       lda floppy_b_spt
        rts

_dfg_read_heads:
        ldx dfg_drive
        bne +
        lda floppy_a_heads
        rts
+       lda floppy_b_heads
        rts

_dfg_read_cyls:
        ldx dfg_drive
        bne +
        lda floppy_a_cyls
        rts
+       lda floppy_b_cyls
        rts

_dfg_read_type:
        ldx dfg_drive
        bne +
        lda floppy_a_type
        rts
+       lda floppy_b_type
        rts

_dfg_msg:
        .text "FLOPPY: ", 0
_dfg_360:
        .text "360K", 0
_dfg_720:
        .text "720K", 0
_dfg_12m:
        .text "1.2MB", 0
_dfg_144:
        .text "1.44MB", 0

; Floppy geometry (detected from BPB at boot) — in non-ZP RAM
; to avoid KERNAL IRQ corruption during init CHROUT calls
floppy_a_spt:
        .byte 0
floppy_a_heads:
        .byte 0
floppy_a_cyls:
        .byte 0
floppy_a_type:
        .byte 0
floppy_a_loaded:
        .byte 0
floppy_a_dirty:
        .byte 0                 ; Set to 1 when INT 13h AH=03 writes to drive A
floppy_b_spt:
        .byte 0
floppy_b_heads:
        .byte 0
floppy_b_cyls:
        .byte 0
floppy_b_type:
        .byte 0
floppy_b_loaded:
        .byte 0
floppy_b_dirty:
        .byte 0                 ; Set to 1 when INT 13h AH=03 writes to drive B

; Page-aligned filename for Hyppo setname
; Must be at a $xx00 address, null-terminated
        .align 256
floppy_fname_page:
        .fill 64,0
        ; 63 chars max + null terminator = 64 bytes
        ; Pad rest of page is automatic from .align
