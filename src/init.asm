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

        ; Load BIOS to bank 5 at $0100 (linear $50100 = F000:0100)
        ; A=$40 = MEGA65 KERNAL: force load to X/Y address, ignore file header
        lda #$40
        ldx #$00                ; Load address low
        ldy #$01                ; Load address high ($0100 in bank 5)
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
        ; BIOS loaded at $50100 (org 100h). Table pointers at $50102.
        ; Each pointer is a 16-bit offset within F000 segment.
        ; We have 20 tables, each 256 bytes.
        ;
        ; Read pointer for table 0:
        ;   ptr = word at $50102
        ;   table_data = $50000 + ptr  (ptr already includes $100 base)
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

        ; Patch TBL_XLAT_OP: opcode $0F → xlat $30 (op_emu_special)
        ; The BIOS decode table maps $0F to $01 (MOV reg,imm) but
        ; 8086tiny uses $0F as an emulator trap prefix. Patch it to
        ; our op_emu_special handler so 0F xx traps work.
        lda #$0F
        sta temp_ptr
        lda #>TBL_XLAT_OP
        sta temp_ptr+1
        lda #$01                ; Bank 1
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda #$30
        ldz #0
        sta [temp_ptr],z

        ; Patch TBL_BASE_SIZE: opcode $0F → 0 (handler fetches sub-opcode itself)
        lda #$0F
        sta temp_ptr
        lda #>TBL_BASE_SIZE
        sta temp_ptr+1
        ; Bank 1 and byte 3 already set from above
        lda #$00
        ldz #0
        sta [temp_ptr],z

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
        ; JMP FAR F000:015C = EA 5C 01 00 F0
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
        lda #$5C                ; Offset low = $5C
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF2
        lda #$01                ; Offset high = $01 (F000:015C)
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF3
        lda #$00                ; Segment low = $00
        sta [temp_ptr],z
        inc temp_ptr            ; $5FFF4
        lda #$F0                ; Segment high = $F0 (F000)
        sta [temp_ptr],z

        ; --- Fill IVT from BIOS int_table (DISABLED — BIOS does this itself) ---
        ; First, clear all 256 IVT entries to F000:FF00 (default IRET)
        ;lda #$00
        ;sta temp_ptr
        ;sta temp_ptr+1
        ;lda #$04                ; Bank 4
        ;sta temp_ptr+2
        ;lda #$00
        ;sta temp_ptr+3
        ;ldy #0
;_ivt_clear:
        ;lda #$00
        ;ldz #0
        ;sta [temp_ptr],z
        ;lda #$FF
        ;ldz #1
        ;sta [temp_ptr],z
        ;lda #$00
        ;ldz #2
        ;sta [temp_ptr],z
        ;lda #$F0
        ;ldz #3
        ;sta [temp_ptr],z
        ;clc
        ;lda temp_ptr
        ;adc #4
        ;sta temp_ptr
        ;bcc +
        ;inc temp_ptr+1
;+       iny
        ;bne _ivt_clear

        ; Now read BIOS int_table pointer from fixed offset $012A
        ;lda #$2A
        ;sta temp_ptr
        ;lda #$01
        ;sta temp_ptr+1
        ;lda #$05                ; Bank 5
        ;sta temp_ptr+2
        ;lda #$00
        ;sta temp_ptr+3
        ;ldz #0
        ;lda [temp_ptr],z        ; int_table ptr low
        ;sta scratch_a
        ;ldz #1
        ;lda [temp_ptr],z        ; int_table ptr high
        ;sta scratch_b
        ; Read itbl_size pointer
        ;ldz #2
        ;lda [temp_ptr],z        ; itbl_size ptr low
        ;sta scratch_c
        ;ldz #3
        ;lda [temp_ptr],z        ; itbl_size ptr high
        ;sta scratch_d

        ; Read actual size from itbl_size pointer
        ;lda scratch_c
        ;sta temp_ptr
        ;lda scratch_d
        ;sta temp_ptr+1
        ; temp_ptr+2 still $05 (bank 5)
        ;ldz #0
        ;lda [temp_ptr],z        ; size low
        ;sta $8F80
        ;ldz #1
        ;lda [temp_ptr],z        ; size high
        ;sta $8F81

        ; DMA copy int_table from BIOS to guest IVT at $40000
        ;lda scratch_a
        ;sta dma_src_lo
        ;lda scratch_b
        ;sta dma_src_hi
        ;lda #$05
        ;sta dma_src_bank
        ;lda #$00
        ;sta dma_dst_lo
        ;sta dma_dst_hi
        ;lda #$04                ; Bank 4
        ;sta dma_dst_bank
        ;lda $8F80
        ;sta dma_count_lo
        ;lda $8F81
        ;sta dma_count_hi
        ;jsr do_dma_chip_copy

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

        ; Write BIOS model byte at F000:FFFE (bank 5 offset $FFFE)
        ; Can't put this in bios.asm since it would require padding to 64K
        lda #$FE
        sta temp_ptr
        lda #$FF
        sta temp_ptr+1
        lda #$05
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3
        lda #$FE                ; 0xFE = IBM PC/XT
        ldz #0
        sta [temp_ptr],z

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
        lda floppy_a_spt          ; SPT from detected geometry
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

        ; Boot through BIOS via reset vector at F000:FFF0
        ; Reset vector contains JMP FAR F000:015C → bios_entry
        lda #$00
        sta reg_cs
        lda #$F0
        sta reg_cs+1            ; CS = $F000
        lda #$F0
        sta reg_ip
        lda #$FF
        sta reg_ip+1            ; IP = $FFF0

        ; Stack uninitialized — BIOS sets SS:SP itself
        lda #$00
        sta reg_ss
        sta reg_ss+1            ; SS = $0000
        sta reg_sp86
        sta reg_sp86+1          ; SP = $0000

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


