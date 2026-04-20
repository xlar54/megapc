; ============================================================================
; globals.asm — All Global Variable Definitions (formerly zeropage.asm)
; ============================================================================
;
; Centralized address definitions. Do NOT define `= $xxxx` constants in any
; other source file — put them here. This is the only way to detect overlaps.
;
; Layout overview:
;   $00-$BF        Zero page: 8086 register file, decoder state, scratch
;   $8E00-$8E6F    FAT writer state (fat_*)
;   $8F00-$8FFF    Emulator state (non-ZP, KERNAL-safe area)
;
; KERNAL IRQ trashes ZP $90-$FA, so save/restore if IRQs enabled.
; Pointers at $70+ are safe only with IRQs off (SEI).
; When calling CHROUT (needs IRQs), save $90-$FA first.

; ============================================================================
; ZERO PAGE ($00-$FF)
; ============================================================================

; --- 8086 Register File ($02-$1F) ---
; Register order matches 8086tiny: AX,CX,DX,BX,SP,BP,SI,DI,ES,CS,SS,DS
regs            = $02
reg_ax          = regs + 0      ; AX (AL=+0, AH=+1)
reg_al          = regs + 0
reg_ah          = regs + 1
reg_cx          = regs + 2      ; CX (CL=+2, CH=+3)
reg_cl          = regs + 2
reg_ch          = regs + 3
reg_dx          = regs + 4      ; DX (DL=+4, DH=+5)
reg_dl          = regs + 4
reg_dh          = regs + 5
reg_bx          = regs + 6      ; BX (BL=+6, BH=+7)
reg_bl          = regs + 6
reg_bh          = regs + 7
reg_sp86        = regs + 8      ; SP (16-bit)
reg_bp86        = regs + 10     ; BP (16-bit)
reg_si          = regs + 12     ; SI (16-bit)
reg_di          = regs + 14     ; DI (16-bit)
reg_es          = regs + 16     ; ES (16-bit)
reg_cs          = regs + 18     ; CS (16-bit)
reg_ss          = regs + 20     ; SS (16-bit)
reg_ds          = regs + 22     ; DS (16-bit)
reg_zero        = regs + 24     ; Always 0 (scratch pair)
reg_scratch     = regs + 26     ; Scratch register

; Segment register offsets from regs base (for indexing)
SEG_ES_OFS      = 16
SEG_CS_OFS      = 18
SEG_SS_OFS      = 20
SEG_DS_OFS      = 22

; --- 8086 FLAGS ($20-$29) ---
flags           = $20
flag_cf         = flags + 0     ; Carry
flag_pf         = flags + 1     ; Parity
flag_af         = flags + 2     ; Auxiliary carry
flag_zf         = flags + 3     ; Zero
flag_sf         = flags + 4     ; Sign
flag_tf         = flags + 5     ; Trap
flag_if         = flags + 6     ; Interrupt enable
flag_df         = flags + 7     ; Direction
flag_of         = flags + 8     ; Overflow

; --- Decoder State ($30-$41) ---
raw_opcode      = $30
xlat_opcode     = $31
extra_field     = $32
i_mod_sz        = $33
set_flags_type  = $34
i_w             = $35
i_d             = $36
i_reg4bit       = $37
i_mod           = $38
i_rm            = $39
i_reg           = $3A
i_data0         = $3B
i_data1         = $3D
i_data2         = $3F
decode_ip_start = $68

; --- Emulator Working Variables ($42-$5F) ---
reg_ip          = $42
op_source       = $44
op_dest         = $48
op_result       = $4C
op_to_addr      = $50
op_from_addr    = $54
rm_addr         = $58

; --- Segment/Prefix State ($60-$6F) ---
seg_override_en = $60
seg_override    = $61
rep_override_en = $62
rep_mode        = $63
trap_flag_var   = $64
int8_asap       = $65
advance_ip      = $66
disk_sect_left  = $67

; --- 32-bit Pointers ($70-$8F) ---
opcode_ptr      = $70           ; CS:IP linear address (4 bytes)
temp_ptr        = $74           ; General purpose pointer (4 bytes)
temp_ptr2       = $78           ; Second pointer (4 bytes)
temp32          = $7C           ; Temp 32-bit value
seg_base        = $80           ; Computed segment base (4 bytes)
cs_base         = $84           ; CS base chip address (4 bytes)
ss_base         = $88           ; SS base chip address (4 bytes)
ds_base         = $8C           ; DS base chip address (4 bytes)

; --- Cache State ($90-$9F) — KERNAL DANGER ZONE ---
cache_page_hi   = $90           ; 4 bytes: page high (bits 16-19) per line
cache_page_lo   = $94           ; 4 bytes: page low (bits 8-15) per line
cache_dirty     = $98           ; 4 bytes: dirty flag per line
cache_next_line = $9C           ; Round-robin pointer (0-3)
cs_dirty        = $9D
ss_dirty        = $9E
ds_dirty        = $9F

; --- Counters / Debug ($A0-$AF) ---
inst_counter    = $A0
tick_counter    = $A2
unimpl_count    = $A4
unimpl_last     = $A5

; --- Scratch ($B0-$BF) ---
scratch_a       = $B0
scratch_b       = $B1
scratch_c       = $B2
scratch_d       = $B3
ea_offset_lo    = $B4
ea_offset_hi    = $B5
ea_seg_ofs      = $B6
cs_in_attic     = $B7
cs_base_linear  = $B8           ; 4 bytes: $B8-$BB
code_cache_pg_lo = $BC
code_cache_pg_hi = $BD
floppy_ofs      = $BE           ; 3 bytes: $BE-$C0

; ============================================================================
; FAT WRITER STATE ($8E00-$8E6F)
; ============================================================================
; Used by fat_writer.asm for FAT32 file save operations.

fat_partition_start     = $8E00 ; 4 bytes: SD sector of FAT32 partition
fat_sectors_per_cluster = $8E04 ; 1 byte
fat_reserved_sectors    = $8E05 ; 2 bytes
fat_sectors_per_fat     = $8E07 ; 4 bytes
fat_first_cluster       = $8E0B ; 4 bytes
fat_fat1_sector         = $8E0F ; 4 bytes
fat_fat2_sector         = $8E13 ; 4 bytes
fat_data_sector         = $8E17 ; 4 bytes
fat_dir_sector          = $8E1B ; 4 bytes
fat_dir_offset          = $8E1F ; 2 bytes
fat_file_cluster        = $8E21 ; 4 bytes
fat_cur_cluster         = $8E25 ; 4 bytes
fat_sector_in_cluster   = $8E29 ; 1 byte
fat_file_size           = $8E2A ; 4 bytes
fat_remaining           = $8E2E ; 4 bytes
fat_attic_bank          = $8E32 ; 1 byte
fat_attic_lo            = $8E33 ; 1 byte (low byte of 16-bit attic offset)
fat_attic_hi            = $8E34 ; 1 byte (high byte)
fat_tmp0                = $8E40 ; 4 bytes
fat_tmp1                = $8E44 ; 4 bytes
fat_fat_offset          = $8E50 ; 2 bytes
fat_fat_sec_idx         = $8E52 ; 4 bytes
; INTENTIONAL REUSE: fat_fat1_abs (FAT-write phase) and the dir-traversal
; pair (fat_dir_save_a / fat_cluster_base) share $8E58-$8E5D. Only one
; phase is active at a time inside fat_writer.asm — never both.
fat_fat1_abs            = $8E56 ; 4 bytes (FAT write only)
fat_dir_save_a          = $8E58 ; 2 bytes (dir traversal only — aliases fat_fat1_abs+2)
fat_cluster_base        = $8E5A ; 2 bytes (dir traversal only)
fat_name_count          = $8E60 ; 1 byte
fat_ext_flag            = $8E61
fat_ext_count           = $8E62
fat_direntry_created    = $8E63
fat_max_cluster         = $8E64 ; 4 bytes
fat_chain_allocated     = $8E68

; ============================================================================
; EMULATOR STATE ($8F00-$8FFF) — NON-ZP RAM
; ============================================================================
; KERNAL does NOT touch this range, so safe from CHROUT/IRQ corruption.

; --- Decoder/IRQ shadow state ($8F00-$8F1F) ---
sti_shadow_flag = $8F00         ; STI shadow (1 instruction inhibit) - decode.asm
div_by_zero_count = $8F14       ; Count of divide-by-zero / INT 0 - opcodes.asm
last_frame_ctr  = $8F15         ; Last BIOS frame counter value - decode/io
sub_frame_ctr   = $8F16         ; Sub-frame counter for INT 8 timing - decode/io
bda_repair_done = $8F17         ; 1 = BDA repair has been done - decode/main
i13_count_save  = $8F18         ; Saved sector count for INT 13h - disk
i13_bx_save_lo  = $8F19         ; Saved BX low for INT 13h - disk
i13_bx_save_hi  = $8F1A         ; Saved BX high for INT 13h - disk
irq_inhibit     = $8F1B         ; Interrupt inhibit (STI/MOV SS/POP SS shadow)
shift_orig_msb  = $8F1C         ; Saved original MSB for SHR OF computation
shift_orig_count = $8F1D        ; Saved original count for shift OF computation
ctrlc_pending   = $8F1E         ; Ctrl-C pending flag - io/main
ovrflw_byte_17  = $8F0E         ; 17th bit of remainder (mul/div overflow byte)

; --- FAT save handoff scratch ($8F25) ---
; Used by disk.asm save_floppy_drive → fat_writer.asm flow.
; Caller writes drive number, fat_writer writes back success/failure.
; Kept SEPARATE from screen/io scratch ($8F26+) to avoid clobbering.
fat_save_drive  = $8F25         ; In: drive # (0/1); Out: 1=success, 0=fail

; --- Screen/console scratch ($8F26-$8F27) ---
; CRITICAL: do_clear_window / do_clear_window_scr in io.asm use these as
; row counters. Anything else placed here will be silently corrupted by
; every screen clear. DO NOT REUSE for persistent state.
scr_clear_row   = $8F26         ; do_clear_window current row
scr_clear_row_s = $8F27         ; do_clear_window_scr current row

; --- FAT save bank handoff ($8F28) ---
; NOTE: previously was $8F26, which collides with scr_clear_row.
; Moved here to avoid corruption when screen clears during save.
fat_save_bank   = $8F28         ; Attic bank passed from disk.asm → fat_writer.asm

; --- Floppy geometry state ($8F30-$8F3D) ---
; CRITICAL: must NOT overlap $8F26-$8F27 (screen clear scratch).
floppy_a_spt    = $8F30
floppy_a_heads  = $8F31
floppy_a_cyls   = $8F32
floppy_a_type   = $8F33
floppy_a_loaded = $8F34
floppy_a_dirty  = $8F35
floppy_b_spt    = $8F36
floppy_b_heads  = $8F37
floppy_b_cyls   = $8F38
floppy_b_type   = $8F39
floppy_b_loaded = $8F3A
floppy_b_dirty  = $8F3B
floppy_a_bank   = $8F3C
floppy_b_bank   = $8F3D

; --- Misc emulator scratch ---
attic_access    = $8F48         ; 1 = current access needs attic DMA
mem_scratch_a   = $8F60         ; mem.asm scratch (used in seg_ofs_to_linear etc.)
mem_scratch_b   = $8F61
mem_scratch_seg = $8F62         ; Saved segment offset
pusha_saved_sp  = $8F70         ; 2 bytes: saved SP for PUSHA instruction
imul_idiv_sign1 = $8F72         ; IMUL/IDIV sign flag (quotient sign)
imul_idiv_sign2 = $8F73         ; IDIV remainder sign

; --- Console scroll/clear scratch ($8F9A-$8F9D) ---
; Used by io.asm console code
scr_disarm      = $8F9A
scr_save_row    = $8F9B
scr_save_col    = $8F9C
scr_save_char   = $8F9D

; --- RTC / Date scratch ($8FA0-$8FAB) ---
; opcodes.asm uses these for INT 1Ah (RTC) and as 4-byte scratch for math
rtc_seconds     = $8FA0
rtc_minutes     = $8FA1
rtc_hours       = $8FA2
rtc_day         = $8FA3
rtc_month       = $8FA4
rtc_year        = $8FA5
rtc_weekday     = $8FA6
rtc_scratch     = $8FA8         ; 4-byte scratch for date math ($8FA8-$8FAB)

; --- Division working variables ($8F02-$8F0D) ---
div_dividend    = $8F02         ; 4 bytes
div_divisor     = $8F06         ; 2 bytes
div_quotient    = $8F08         ; 4 bytes
div_remainder   = $8F0C         ; 2 bytes

; --- Display / video state ($8FD0-$8FF0) ---
; opcodes.asm AH=09 string output:
str_ptr_lo      = $8FD0         ; Source string pointer (used in INT 21h AH=09)
str_ptr_hi      = $8FD1
str_ptr_bank    = $8FD2

; disk.asm unsupported AH counter:
i13_unsup_count = $8FD3         ; Count of unsupported INT 13h calls

; display.asm CGA refresh state:
disp_count_lo   = $8FD4
disp_count_hi   = $8FD5
disp_color_lo   = $8FD6
disp_color_hi   = $8FD7

; io.asm scroll/scratch:
io_line_count   = $8FD8         ; Saved line count for scroll
io_crtc_reg     = $8FD9         ; CRTC selected register (also 'screen code')
io_save_a       = $8FDA         ; Generic save A
io_save_b       = $8FDB         ; Generic save B
io_save_c       = $8FDC
io_save_d       = $8FDD

; --- Disk INT 13h active geometry ($8FE0-$8FE4) ---
i13_cur_spt     = $8FE0
i13_cur_heads   = $8FE1
i13_cur_cyls    = $8FE2
i13_cur_type    = $8FE3
i13_cur_bank    = $8FE4         ; Attic bank offset ($10=A, $20=B)

; --- PC speaker / PIT ($8FE8-$8FEB) ---
spk_pit_lobyte  = $8FE8         ; PIT divider low byte
spk_pit_hibyte  = $8FE9         ; PIT divider high byte
spk_pit_latch   = $8FEA         ; 0=expecting low byte, 1=expecting high byte
spk_port61      = $8FEB         ; Current port $61 value

; --- Long division working area ($8FEC-$8FF0) ---
ldiv_dividend0  = $8FEC         ; Long division dividend byte 0
ldiv_dividend1  = $8FED         ; byte 1
ldiv_dividend2  = $8FEE         ; byte 2
ldiv_result_lo  = $8FEF         ; Result low
ldiv_result_hi  = $8FF0         ; Result high

; ============================================================================
; FIXED CHIP RAM BUFFERS ($9000-$9FFF)
; ============================================================================
; Used by both main emulator and fat_writer.
SECTOR_BUF      = $9800         ; 512-byte sector buffer ($9800-$99FF)
