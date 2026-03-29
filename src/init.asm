; ============================================================================
; init.asm — Initialization
; ============================================================================
;
; Startup sequence:
;   1. Load BIOS binary from disk to bank 5 ($50000)
;   2. Extract 20 decode tables from BIOS to bank 1 ($12000)
;   3. Clear guest RAM (bank 4)
;   4. Set up IVT with default handlers
;   5. Set up BDA (BIOS Data Area)
;   6. Load floppy image to attic RAM
;   7. Copy boot sector to $07C00
;   8. Initialize 8086 registers to power-on state
;
; BIOS binary format (8086tiny compatible):
;   Offset $0000–$00FF: Register file (F000:0000–F000:00FF)
;   Offset $0100+:      BIOS code (F000:0100+)
;   Table pointers at register_file + $0102 (word pairs: offset, count)
;   Actual table data at register_file + pointer_value

; ============================================================================
; init_tables — Load BIOS and extract decode tables
; ============================================================================
init_tables:
        ; --- TEST MODE (disabled): ---
        ; jsr test_bios
        ; rts
        ; --- Real BIOS load ---
        ; Close all file channels from autoload
        ;jsr $FFE7               ; CLALL

        ; Set bank for LOAD (A=data bank, X=filename bank)
        lda #$05
        ldx #$00
        jsr SETBNK

        ; Set file parameters: logical #0, device 8, secondary 0
        lda #$00
        ldx #$08
        ldy #$00
        jsr SETLFS

        ; Set filename
        lda #_bios_fname_end-_bios_fname                  ; Filename length
        ldx #<_bios_fname
        ldy #>_bios_fname
        jsr SETNAM

        ; Load BIOS to bank 5 at $0000 (linear $50000 = F000:0000)
        ; A=$40 = MEGA65 KERNAL: force load to X/Y address, ignore file header
        lda #$40
        ldx #$00                ; Load address low
        ldy #$01                ; Load address high ($0000 in bank 5)
        jsr LOAD

        pha
        php
        lda #$47
        sta $D02F
        lda #$53
        sta $D02F
        lda #$70
        tsb $D054
        plp
        pla

        bcs _init_load_err

        ; Re-unlock VIC-IV (KERNAL LOAD resets it!)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031               ; Re-enable 40MHz
        lda #$80
        tsb VIC_HOTREGS         ; Re-disable hot registers

        ; --- Extract decode tables ---
        ; BIOS register file base is at $50000 (F000:0000)
        ; Table pointers start at $50000 + $102 = $50102
        ; Each table pointer is a 16-bit offset from register file base
        ; We have 20 tables, each 256 bytes
        ;
        ; Read pointer for table 0:
        ;   ptr = word at $50102
        ;   table_data = $50000 + ptr
        ;   DMA copy 256 bytes to TBL_BASE + (0 * 256)

        ldx #0                  ; Table index (0–19)
_et_loop:
        ; Calculate pointer address: $50102 + (X * 2)
        txa
        asl                     ; × 2
        clc
        adc #$02                ; + $02
        sta temp_ptr            ; Low byte
        lda #$01                ; $50102 base → $01xx high byte
        adc #0
        sta temp_ptr+1
        lda #$05                ; Bank 5
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ; Read 16-bit pointer value
        phx
        ldz #0
        lda [temp_ptr],z
        sta scratch_a           ; ptr_lo
        ldz #1
        lda [temp_ptr],z
        sta scratch_b           ; ptr_hi

        ; Source address = $50000 + ptr
        ; DMA copy 256 bytes from bank 5 to TBL_BASE + (X * 256)
        lda scratch_a
        sta dma_src_lo
        lda scratch_b
        sta dma_src_hi
        lda #$05
        sta dma_src_bank        ; Source: bank 5

        ; Dest: TBL_BASE + (table_index * 256)
        ; TBL_BASE = $12000
        ; Table X: $12000 + X*256 = $120XX where XX = X
        plx
        phx
        lda #$00
        sta dma_dst_lo          ; Low byte always 0 (256-byte aligned)
        lda #>TBL_BASE
        clc
        txa                     ; Table index
        adc #>TBL_BASE          ; $20 + X
        sta dma_dst_hi
        lda #$01                ; Bank 1
        sta dma_dst_bank

        ; Count = 256
        lda #$00
        sta dma_count_lo
        lda #$01
        sta dma_count_hi

        jsr do_dma_chip_copy

        plx
        inx
        cpx #20
        bne _et_loop

        ; Print table load confirmation
        ldx #0
-       lda _tbl_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        rts

_init_load_err:
        ; Re-unlock VIC-IV even on error
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        cli                     ; Enable IRQs for CHROUT
        ldx #0
-       lda _err_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+       jmp *                   ; Halt on error

_bios_fname:
        .text "bios.bin"
_bios_fname_end:

_tbl_msg:
        .text "TABLES LOADED OK", 13, 0
_err_msg:
        .text "ERROR LOADING BIOS!", 13, 0

; ============================================================================
; init_guest_mem — Clear guest RAM and set up IVT/BDA
; ============================================================================
init_guest_mem:
        ; --- Clear bank 4 (64KB guest RAM segment 0) ---
        ; DMA fill $40000–$4FFFF with $00
        lda #$00
        sta dma_src_lo
        sta dma_src_hi
        lda #$04
        sta dma_src_bank
        lda #$00
        sta dma_dst_lo
        sta dma_dst_hi
        lda #$04
        sta dma_dst_bank
        ; For a fill, we use DMA command $03 (fill)
        jsr _do_fill_bank4

        ; --- Clear attic guest RAM ($10000–$EFFFF mapped at attic) ---
        ; Clear 14 banks (each 64KB) at attic $8010000–$80EFFFF
        ldx #$01
_cga_loop:
        phx
        jsr _clear_attic_bank
        plx
        inx
        cpx #$0F
        bcc _cga_loop

        ; --- Set up IVT (Interrupt Vector Table) ---
        ; 256 entries × 4 bytes at $40000
        ; Default: all vectors point to a dummy IRET at F000:FF00
        ; We'll put an IRET instruction at $5FF00 (F000:FF00)
        lda #$CF                ; IRET opcode
        sta temp_ptr
        lda #$FF
        sta temp_ptr+1
        lda #$05                ; Bank 5
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda #$CF
        ldz #0
        sta [temp_ptr],z

        ; --- Write reset vector at F000:FFF0 ($5FFF0) ---
        ; JMP FAR F000:0100 = EA 00 01 00 F0
        ; NOTE: [ptr],z only works reliably with Z=0 on MEGA65/XEMU
        ; So we increment the pointer for each byte
        lda #$F0
        sta temp_ptr
        lda #$FF
        sta temp_ptr+1
        lda #$05                ; Bank 5
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldz #0
        lda #$EA                ; JMP FAR opcode
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF1
        lda #$00                ; Offset low = $00
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF2
        lda #$01                ; Offset high = $01 (F000:0100)
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF3
        lda #$00                ; Segment low = $00
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF4
        lda #$F0                ; Segment high = $F0 (F000)
        sta [temp_ptr],z

        ; Fill IVT: each entry = $FF00 (IP), $F000 (CS)
        lda #$00
        sta temp_ptr
        lda #$00
        sta temp_ptr+1
        lda #$04                ; Bank 4
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldy #0                  ; Counter: 0–255
_ivt_loop:
        ; IP low
        lda #$00
        ldz #0
        sta [temp_ptr],z
        ; IP high
        lda #$FF
        ldz #1
        sta [temp_ptr],z
        ; CS low
        lda #$00
        ldz #2
        sta [temp_ptr],z
        ; CS high
        lda #$F0
        ldz #3
        sta [temp_ptr],z

        ; Advance pointer by 4
        clc
        lda temp_ptr
        adc #4
        sta temp_ptr
        bcc +
        inc temp_ptr+1
+
        iny
        bne _ivt_loop           ; 256 iterations

        ; --- Set INT 1Eh vector to disk parameter table at F000:F000 ---
        ; IVT entry 1Eh = 4 bytes at linear $0078 (bank 4 $40078)
        lda #$78
        sta temp_ptr
        lda #$00
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda #$00                ; IP low = $00
        ldz #0
        sta [temp_ptr],z
        lda #$F0                ; IP high = $F0 (offset $F000)
        ldz #1
        sta [temp_ptr],z
        lda #$00                ; CS low = $00
        ldz #2
        sta [temp_ptr],z
        lda #$F0                ; CS high = $F0 (segment $F000)
        ldz #3
        sta [temp_ptr],z

        ; Write disk parameter table at F000:F000 (bank 5 $5F000)
        jsr _init_write_dpt

        ; --- Set up BDA (BIOS Data Area) at $40400 ---
        ; Equipment word at $40410: bit 0=floppy present
        lda #$10
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #$04
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda #VIDEO_EQUIP        ; Floppy + video mode from config
        ldz #0
        sta [temp_ptr],z

        ; Conventional memory size at $40413
        lda #$13
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #RAM_KB_LO
        ldz #0
        sta [temp_ptr],z
        lda #RAM_KB_HI
        ldz #1
        sta [temp_ptr],z

        ; Video mode at $40449
        lda #$49
        sta temp_ptr
        lda #$04
        sta temp_ptr+1
        lda #VIDEO_MODE
        ldz #0
        sta [temp_ptr],z

        ; Columns at $4044A: 80
        lda #$4A
        sta temp_ptr
        lda #80
        ldz #0
        sta [temp_ptr],z

        ; Regen buffer size at $4044C: 4000 bytes (80*25*2 = $0FA0)
        lda #$4C
        sta temp_ptr
        lda #$A0                ; Low byte of $0FA0
        ldz #0
        sta [temp_ptr],z
        lda #$0F                ; High byte of $0FA0
        ldz #1
        sta [temp_ptr],z

        ; CRT page start at $4044E: $0000 (page 0 starts at offset 0)
        lda #$4E
        sta temp_ptr
        lda #$00
        ldz #0
        sta [temp_ptr],z
        ldz #1
        sta [temp_ptr],z

        ; Cursor positions at $40450: row 0, col 0 for all 8 pages
        ; (Already zeroed by memory clear)

        ; Cursor shape at $40460: start=6, end=7 (underline cursor)
        lda #$60
        sta temp_ptr
        lda #$07                ; End scan line
        ldz #0
        sta [temp_ptr],z
        lda #$06                ; Start scan line
        ldz #1
        sta [temp_ptr],z

        ; CRT controller base port at $40463
        lda #$63
        sta temp_ptr
        lda #<CRTC_PORT
        ldz #0
        sta [temp_ptr],z
        lda #>CRTC_PORT
        ldz #1
        sta [temp_ptr],z

        ; Active display page at $40462: 0
        lda #$62
        sta temp_ptr
        lda #$00
        ldz #0
        sta [temp_ptr],z

        ; Timer tick count at $4046C (NOT $4006C!)
        ; Starts at 0 — will be incremented by INT 8 handler
        ; (Address confirmed from debugging sessions)

        ldx #0
-       lda _mem_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        rts

; --- Helper: Write disk parameter table to F000:F000 ---
_init_write_dpt:
        lda #$00
        sta temp_ptr
        lda #$F0
        sta temp_ptr+1
        lda #$05                ; Bank 5 (F000 segment)
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        ldz #0
        lda #$CF                ; SRT/HUT
        sta [temp_ptr],z
        ldz #1
        lda #$02                ; DMA/HLT
        sta [temp_ptr],z
        ldz #2
        lda #$25                ; Motor off delay
        sta [temp_ptr],z
        ldz #3
        lda #$02                ; Bytes/sector code (2=512)
        sta [temp_ptr],z
        ldz #4
        lda floppy_spt          ; SPT from detected geometry
        sta [temp_ptr],z
        ldz #5
        lda #$2A                ; Gap length
        sta [temp_ptr],z
        ldz #6
        lda #$FF                ; Data length
        sta [temp_ptr],z
        ldz #7
        lda #$50                ; Format gap length
        sta [temp_ptr],z
        ldz #8
        lda #$F6                ; Format fill byte
        sta [temp_ptr],z
        ldz #9
        lda #$0F                ; Head settle time
        sta [temp_ptr],z
        ldz #10
        lda #$08                ; Motor start time
        sta [temp_ptr],z
        rts

; --- Helper: Fill bank 4 with zeros ---
_do_fill_bank4:
        lda #$00
        sta dma_dst_lo
        sta dma_dst_hi
        lda #$04
        sta dma_dst_bank
        lda #$00
        sta dma_count_lo        ; $0000 = 65536
        sta dma_count_hi
        lda #$00                ; Fill with zero
        jsr do_dma_fill
        rts

; --- Helper: Clear one 64KB attic bank ---
; Input: X = bank number ($01–$0E)
_clear_attic_bank:
        lda #$00
        sta dma_dst_lo
        sta dma_dst_hi
        sta dma_count_lo        ; $0000 = 65536
        sta dma_count_hi
        txa
        sta dma_dst_bank        ; Bank number (do_dma_fill_attic adds $08)
        lda #$00                ; Fill with zero
        jsr do_dma_fill_attic
        rts

_mem_msg:
        .text "GUEST MEM INITIALIZED", 13, 0

; ============================================================================
; init_regs — Set 8086 registers to power-on defaults
; ============================================================================
init_regs:
        ; Clear all registers
        ldx #27
        lda #0
-       sta regs,x
        dex
        bpl -

        ; Clear all flags
        ldx #8
-       sta flags,x
        dex
        bpl -

        ; Clear decoder state
        ldx #$41
-       sta $30,x
        dex
        bpl -

        ; Power-on register values (8086 reset vector)
        ; CS = $F000, IP = $FFF0 (reset vector at F000:FFF0)
        lda #$00
        sta reg_cs
        lda #$F0
        sta reg_cs+1
        lda #$F0
        sta reg_ip
        lda #$FF
        sta reg_ip+1

        ; SS = $F000, SP = $F000 (BIOS convention)
        lda #$00
        sta reg_ss
        lda #$F0
        sta reg_ss+1
        lda #$00
        sta reg_sp86
        lda #$F0
        sta reg_sp86+1

        ; DS = ES = $0000
        lda #0
        sta reg_ds
        sta reg_ds+1
        sta reg_es
        sta reg_es+1

        ; Mark all segment bases as dirty
        lda #1
        sta cs_dirty
        sta ss_dirty
        sta ds_dirty

        ; Clear counters
        lda #0
        sta inst_counter
        sta inst_counter+1
        sta tick_counter
        sta tick_counter+1
        sta unimpl_count
        sta unimpl_last
        sta seg_override_en
        sta rep_override_en
        sta int8_asap
        sta trap_flag_var
        sta $8F44               ; Clear attic access counter
        sta $8F45

        ldx #0
-       lda _reg_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        rts

_reg_msg:
        .text "REGS SET TO POWER-ON STATE", 13, 0

; ============================================================================
; load_floppy — Load floppy disk image to attic RAM
; ============================================================================
; load_floppy — Load floppy disk image to attic RAM via Hyppo
; ============================================================================
; Uses Hyppo trap $2E (setname) and $3E (loadfile_attic).
; Loads fd.img from SD card FAT32 to attic at FLOPPY_ATTIC ($8100000).
;
; Hyppo setname: Y = high byte of page-aligned filename, A=$2E, sta $D640, clv
; Hyppo loadfile_attic: X=addr low, Y=addr mid, Z=addr high byte
;   Address is 28-bit: $08ZZYYXX (the $08 prefix means attic)
;   For FLOPPY_ATTIC=$8100000: ZZ=$10, YY=$00, XX=$00
;
; On success: floppy_loaded = 1
; On failure: floppy_loaded = 0, prints error, emulation continues without floppy

load_floppy:
        lda #$00
        sta floppy_loaded

        ; Print loading message
        ldx #0
-       lda _msg_floppy,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; Set Hyppo filename to "fd.img"
        ; Filename must be on a page boundary, null-terminated
        ldy #>floppy_fname_page
        lda #$2E                ; hyppo_setname
        sta $D640
        clv
        bcc _floppy_no_file

        ; Load file to attic RAM at FLOPPY_ATTIC ($8100000)
        ; Hyppo 28-bit address: $08ZZYYXX
        ; $8100000 -> ZZ=$10, YY=$00, XX=$00
        ldz #$10                ; High byte of attic address
        ldy #$00                ; Mid byte
        ldx #$00                ; Low byte
        lda #$3E                ; hyppo_loadfile_attic
        sta $D640
        clv

        ; Re-unlock VIC-IV (Hyppo trap may reset it)
        pha
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031               ; Re-enable 40MHz
        lda #$80
        tsb VIC_HOTREGS         ; Re-disable hot registers
        pla

        bcc _floppy_load_fail

        ; Success!
        lda #$01
        sta floppy_loaded

        ldx #0
-       lda _msg_floppy_ok,x
        beq +
        jsr CHROUT
        inx
        bne -
+       rts

_floppy_no_file:
        ldx #0
-       lda _msg_floppy_nf,x
        beq +
        jsr CHROUT
        inx
        bne -
+       rts

_floppy_load_fail:
        ldx #0
-       lda _msg_floppy_err,x
        beq +
        jsr CHROUT
        inx
        bne -
+       rts

_msg_floppy:
        .text "loading fd.img from sd card...", 0
_msg_floppy_ok:
        .text "ok", 13, 0
_msg_floppy_nf:
        .text "not found (place fd.img on sd card)", 13, 0
_msg_floppy_err:
        .text "load failed", 13, 0

; ============================================================================
; detect_floppy_geom — Auto-detect floppy geometry from BPB
; ============================================================================
; Reads total sectors from sector 0 of the loaded floppy image.
; Matches against known formats to set geometry variables.
; Must be called after load_floppy and before init_guest_mem.
;
detect_floppy_geom:
        ; Set defaults (1.44MB) in case detection fails
        lda #18
        sta floppy_spt
        lda #2
        sta floppy_heads
        lda #80
        sta floppy_cyls
        lda #$04
        sta floppy_type

        ; Skip if no floppy loaded
        lda floppy_loaded
        beq _dfg_done

        ; DMA 512 bytes from FLOPPY_ATTIC to SECTOR_BUF
        lda #$00
        sta dma_src_lo
        sta dma_src_hi
        lda #$10                ; Attic bank offset for floppy ($8100000)
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
        lda #$10
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
        sta floppy_spt
        lda #1
        sta floppy_heads
        lda #40
        sta floppy_cyls
        lda #$01
        sta floppy_type
        bra _dfg_print

_dfg_180k:
        lda #9
        sta floppy_spt
        lda #1
        sta floppy_heads
        lda #40
        sta floppy_cyls
        lda #$01
        sta floppy_type
        bra _dfg_print

_dfg_320k:
        lda #8
        sta floppy_spt
        lda #2
        sta floppy_heads
        lda #40
        sta floppy_cyls
        lda #$01
        sta floppy_type
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
        sta floppy_spt
        lda #2
        sta floppy_heads
        lda #40
        sta floppy_cyls
        lda #$01
        sta floppy_type
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
        sta floppy_spt
        lda #2
        sta floppy_heads
        lda #80
        sta floppy_cyls
        lda #$03
        sta floppy_type
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
        sta floppy_spt
        lda #2
        sta floppy_heads
        lda #80
        sta floppy_cyls
        lda #$02
        sta floppy_type
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
        lda floppy_spt
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
        lda floppy_spt
        jsr _dfg_print_dec
        lda #'/'
        jsr CHROUT
        ; Print heads
        lda floppy_heads
        jsr _dfg_print_dec
        lda #'/'
        jsr CHROUT
        ; Print cylinders
        lda floppy_cyls
        jsr _dfg_print_dec
        lda #' '
        jsr CHROUT
        lda #'('
        jsr CHROUT

        ; Print format name based on type
        lda floppy_type
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

; ============================================================================
; test_bios — Install a small test program in place of real BIOS
; ============================================================================
; Copies hand-assembled 8086 machine code to F000:0100 (bank 5 $50100)
; and writes the reset vector JMP FAR at F000:FFF0 ($5FFF0).
; Also initializes DS=ES=0000 in init_regs.
;
; Test results are written to 0000:7F00 ($47F00 in bank 4).
; Expected results after successful run:
;   $47F00 = $34  (MOV AX,imm — AL stored)
;   $47F01 = $78  (MOV BX,imm — BL stored)
;   $47F02 = $AA  (JMP SHORT success marker)
;   $47F03 = $01  (XOR+INC result)
;   $47F04 = $55  (PUSH/POP result)
;   $47F05 = $CC  (CALL/RET success marker)
;   $47F06 = $DD  (CMP+JZ success marker)
;
test_bios:
        ; Set up pointer to F000:0100 = bank 5 $0100 = linear $50100
        lda #$00
        sta temp_ptr
        lda #$01
        sta temp_ptr+1
        lda #$05
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ; Copy test program bytes
        ldx #0
        ldz #0
_tb_copy:
        lda _test_program,x
        sta [temp_ptr],z
        ; Increment pointer (can't use Z>0 reliably)
        inc temp_ptr
        bne +
        inc temp_ptr+1
+       inx
        cpx #_test_program_end - _test_program
        bne _tb_copy

        ; Write reset vector at F000:FFF0 ($5FFF0)
        ; JMP FAR F000:0100 = EA 00 01 00 F0
        lda #$F0
        sta temp_ptr
        lda #$FF
        sta temp_ptr+1
        lda #$05
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ldz #0
        lda #$EA
        sta [temp_ptr],z
        inc temp_ptr
        lda #$00                ; Offset low
        sta [temp_ptr],z
        inc temp_ptr
        lda #$01                ; Offset high
        sta [temp_ptr],z
        inc temp_ptr
        lda #$00                ; Segment low
        sta [temp_ptr],z
        inc temp_ptr
        lda #$F0                ; Segment high
        sta [temp_ptr],z

        ; Print confirmation
        ldx #0
-       lda _tb_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        rts

_tb_msg:
        .text "TEST BIOS INSTALLED", 13, 0

; 8086 machine code for the test program at F000:0100
; Assumes DS=0000 (segment 0 = bank 4)
; Assumes SS:SP = F000:F000
_test_program:
        ; === Test 8: Code and stack on SAME attic page ===
        ; This mirrors the boot sector: CS=SS=$1FE0
        ; Code at 1FE0:7Cxx (page $27C), stack at 1FE0:7Bxx (page $27B)
        ; BPB data also at 1FE0:7Cxx (page $27C) — shared with code!

        .byte $B4, $0E
        .byte $B0, $54          ; 'T'
        .byte $CD, $10

        ; --- Set up: Write code + data at segment $2000 ---
        ; Code at 2000:0100 (page $201) 
        ; Stack at 2000:0080 (page $200) — SAME as below
        ; Data at 2000:0050 (page $200)
        ; 
        ; Actually, for overlap: put code AND data on the SAME page
        ; Code at 2000:0000-003F  (page $200)
        ; Data at 2000:0040-007F  (page $200, same page as code!)
        ; Stack at 2000:00F0      (page $200, same page!)

        .byte $B8, $00, $20     ; MOV AX, $2000
        .byte $8E, $D8          ; MOV DS, AX

        ; Write subroutine at 2000:0000
        ; It reads data from [0050] (same page), then RETFs
        ;   A1 50 00    MOV AX, [0050]  (read data from same page as code)
        ;   A1 52 00    MOV AX, [0052]
        ;   A1 54 00    MOV AX, [0054]
        ;   CB          RETF
        .byte $B0, $A1
        .byte $A2, $00, $00
        .byte $B0, $50
        .byte $A2, $01, $00
        .byte $B0, $00
        .byte $A2, $02, $00
        .byte $B0, $A1
        .byte $A2, $03, $00
        .byte $B0, $52
        .byte $A2, $04, $00
        .byte $B0, $00
        .byte $A2, $05, $00
        .byte $B0, $A1
        .byte $A2, $06, $00
        .byte $B0, $54
        .byte $A2, $07, $00
        .byte $B0, $00
        .byte $A2, $08, $00
        .byte $B0, $CB
        .byte $A2, $09, $00

        ; Write some data at 2000:0050
        .byte $C7, $06, $50, $00, $AA, $55  ; MOV WORD [0050], $55AA
        .byte $C7, $06, $52, $00, $BB, $66  ; MOV WORD [0052], $66BB
        .byte $C7, $06, $54, $00, $CC, $77  ; MOV WORD [0054], $77CC

        ; Restore DS=0
        .byte $B8, $00, $00
        .byte $8E, $D8

        ; Set SS:SP to 2000:00F0 (same page $200 as code and data!)
        .byte $B8, $00, $20
        .byte $8E, $D0          ; SS=$2000
        .byte $BC, $F0, $00     ; SP=$00F0

        ; Single CALL FAR
        .byte $9A, $00, $00, $00, $20
        ; Success
        .byte $B0, $59          ; 'Y'
        .byte $B4, $0E
        .byte $B0, $38          ; '8'
        .byte $CD, $10

        ; Loop 50 times
        .byte $B9, $32, $00     ; MOV CX, 50
        ; CALL FAR 2000:0000
        .byte $9A, $00, $00, $00, $20
        .byte $E2, $F9          ; LOOP back 7 bytes

        .byte $B4, $0E
        .byte $B0, $39          ; '9'
        .byte $CD, $10

        ; === Test with code on page N, stack on page N ===
        ; Even more extreme: put code at 2000:0080, stack at 2000:00F0
        ; Both on page $200. RETF return address is ON the code page.
        
        ; Write RETF at 2000:0080
        .byte $B8, $00, $20
        .byte $8E, $D8
        .byte $B0, $CB
        .byte $A2, $80, $00     ; [2000:0080] = CB (RETF)
        .byte $B8, $00, $00
        .byte $8E, $D8

        ; SP=$00F0 on page $200, code at $0080 also page $200
        ; Return address pushed at SP-4=$00EC, also page $200
        .byte $B9, $32, $00     ; MOV CX, 50
        .byte $9A, $80, $00, $00, $20  ; CALL FAR 2000:0080
        .byte $E2, $F9          ; LOOP

        .byte $B4, $0E
        .byte $B0, $41          ; 'A'
        .byte $CD, $10

        ; === Test with boot-sector-like layout ===
        ; CS=SS=$1FE0, code at 7C00+, stack near 7B00+
        ; Write RETF at 1FE0:7C00
        .byte $B8, $E0, $1F     ; MOV AX, $1FE0
        .byte $8E, $D8          ; DS=$1FE0
        .byte $B0, $CB
        .byte $A2, $00, $7C     ; [1FE0:7C00] = CB (RETF)
        .byte $B8, $00, $00
        .byte $8E, $D8

        ; Set SS=$1FE0, SP=$7BA8 (matching boot sector)
        .byte $B8, $E0, $1F
        .byte $8E, $D0          ; SS=$1FE0
        .byte $BC, $A8, $7B     ; SP=$7BA8

        ; CALL FAR 1FE0:7C00
        .byte $9A, $00, $7C, $E0, $1F
        ; If we get here, success
        .byte $B4, $0E
        .byte $B0, $42          ; 'B'
        .byte $CD, $10

        ; Loop 50 times
        .byte $B9, $32, $00
        .byte $9A, $00, $7C, $E0, $1F
        .byte $E2, $F9

        .byte $B4, $0E
        .byte $B0, $43          ; 'C'
        .byte $CD, $10

        ; Print OK
        .byte $B4, $0E
        .byte $B0, $0D
        .byte $CD, $10
        .byte $B0, $4F
        .byte $CD, $10
        .byte $B0, $4B
        .byte $CD, $10

        .byte $F4
        .byte $EB, $FE

_test_program_end:
; Page-aligned filename for Hyppo setname
; Must be at a $xx00 address, null-terminated
        .align 256
floppy_fname_page:
        .text "fd.img", 0
        ; Pad rest of page is automatic from .align