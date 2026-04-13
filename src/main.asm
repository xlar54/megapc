; ============================================================================
; MEGA8086 — 8086 Emulator for the MEGA65
; Clean branch — modular design
;
; Build with 64tass:
;   64tass --cbm-prg -o emu8086.prg main.asm
;
; Run in XEMU:
;   xmega65 -8 emu8086.d81 -hdosvirt true -autoload true
; ============================================================================

        .cpu    "45gs02"

; ============================================================================
; BASIC SYS stub — auto-run line: 10 SYS 8210
; ============================================================================
        * = $2001               ; BASIC program start
        .word _basic_end        ; Pointer to next BASIC line
        .word 10                ; Line number 10
        .byte $9E               ; SYS token
        .text "8210"            ; Address of entry point ($2012 = 8210 decimal)
        .byte 0                 ; End of BASIC line
_basic_end:
        .word 0                 ; End of BASIC program

; ============================================================================
; Entry point at $2012
; ============================================================================
        * = $2012

; ============================================================================
; Memory Map Constants
; ============================================================================
;
; Bank 0 ($00000–$0FFFF): Emulator code, ZP, 6502 stack
;   $0000–$00FF  Zero page (8086 regs, decoder, pointers)
;   $0100–$01FF  6502 stack
;   $0200–$07FF  KERNAL workspace
;   $0800–      Emulator code
;
; Bank 1 ($10000–$1FFFF):
;   $12000–$1FFFF  Decode tables (20×256=5KB) + I/O ports + CGA mirror
;     $12000  Decode tables (5120 bytes → $12000–$133FF)
;     $17000  I/O port space (4096 bytes → $17000–$17FFF)
;     $18000  CGA text mirror (4000 bytes → $18000–$18F9F)
;
; Banks 2–3: MEGA65 KERNAL ROM — do not touch
;
; Bank 4 ($40000–$4FFFF): Guest RAM $00000–$0FFFF (fast [ptr],z)
;   Direct-mapped first 64KB of 8086 address space
;   IVT at $40000, BDA at $40400, boot sector at $47C00
;
; Bank 5 ($50000–$5FFFF): BIOS ROM / F-segment (read-only guest)
;   Maps 8086 $F0000–$FFFFF
;   BIOS binary loaded here; must be write-protected
;
; Attic ($8000000+): Guest RAM $10000–$EFFFF
;   Accessed via DMA only — [ptr],z cannot reach attic
;   Multi-line cache in chip RAM for read/write access
;   Also stores floppy disk image
;

; --- Chip RAM addresses ---
GUEST_RAM_BASE  = $040000       ; Bank 4: 8086 seg 0 ($00000–$0FFFF)
BIOS_ROM_BASE   = $050000       ; Bank 5: 8086 F-seg ($F0000–$FFFFF)

TBL_BASE        = $012000       ; Decode tables in bank 1
IO_PORT_BASE    = $017000       ; I/O port space in bank 1
CGA_MIRROR      = $018000       ; CGA text buffer mirror in bank 1

; --- Decode table offsets (each 256 bytes) ---
;  Tables 0–7 from BIOS binary (xlat_opcode_id, extra_field, etc.)
;  Tables 8–19 are BIOS lookup tables
TBL_XLAT_OP     = TBL_BASE + (0 * 256)   ; raw opcode → xlat handler id
TBL_EXTRA_FIELD = TBL_BASE + (1 * 256)   ; extra_field per opcode
TBL_STD_FLAGS   = TBL_BASE + (2 * 256)   ; set_flags_type per opcode
TBL_I_W         = TBL_BASE + (3 * 256)   ; i_w (word/byte) per opcode
TBL_I_D         = TBL_BASE + (4 * 256)   ; i_d (direction) per opcode
TBL_I_MOD_SZ    = TBL_BASE + (5 * 256)   ; modrm size indicator
TBL_BASE_SIZE   = TBL_BASE + (6 * 256)   ; base instruction size
TBL_PARITY      = TBL_BASE + (7 * 256)   ; parity lookup
; BIOS tables (8–19)
TBL_BIOS_08     = TBL_BASE + (8 * 256)
TBL_BIOS_09     = TBL_BASE + (9 * 256)
TBL_BIOS_10     = TBL_BASE + (10 * 256)
TBL_BIOS_11     = TBL_BASE + (11 * 256)
TBL_BIOS_12     = TBL_BASE + (12 * 256)
TBL_BIOS_13     = TBL_BASE + (13 * 256)
TBL_BIOS_14     = TBL_BASE + (14 * 256)
TBL_BIOS_15     = TBL_BASE + (15 * 256)
TBL_BIOS_16     = TBL_BASE + (16 * 256)
TBL_BIOS_17     = TBL_BASE + (17 * 256)
TBL_BIOS_18     = TBL_BASE + (18 * 256)
TBL_BIOS_19     = TBL_BASE + (19 * 256)

; --- Attic addresses ---
ATTIC_BASE      = $8000000      ; 8086 linear 0 in attic
FLOPPY_A_ATTIC  = $8100000      ; Floppy A image in attic (1.44MB at +1MB)
FLOPPY_B_ATTIC  = $8200000      ; Floppy B image in attic (1.44MB at +2MB)
SCREEN_SAVE_ATTIC = $8300000    ; Screen save area in attic (for TAB menu)

; --- Cache constants ---
CACHE_LINES     = 4             ; Number of cache lines
CACHE_LINE_SZ   = 256           ; Bytes per cache line
CACHE_BUF       = $9200         ; Cache buffer in bank 0 (4×256 = 1KB)
CODE_CACHE_BUF  = $9000         ; 256-byte code cache buffer
CODE_CACHE_SPILL = $9100        ; 8-byte spillover from next page
                                ; $9200–$95FF
CACHE_INVALID   = $FF           ; Sentinel: no page cached

; --- RAM size ---
; Conventional memory reported to DOS via INT 12h and BDA
RAM_KB          = 640           ; 64 = 64KB (bank 4 only), 640 = full conventional
RAM_KB_LO       = <RAM_KB       ; Low byte for registers
RAM_KB_HI       = >RAM_KB       ; High byte for registers

; --- Video mode ---
; Set VIDEO_MODE to 3 for CGA color, 7 for monochrome
; All other constants derive automatically
VIDEO_MODE      = 7             ; 3 = 80x25 color (CGA), 7 = 80x25 mono (MDA)
.if VIDEO_MODE == 3
VIDEO_EQUIP     = $61           ; 2 floppies + 80-col CGA
CRTC_PORT       = $03D4         ; CGA CRTC base port
.elsif VIDEO_MODE == 7
VIDEO_EQUIP     = $71           ; 2 floppies + 80-col monochrome
CRTC_PORT       = $03B4         ; MDA CRTC base port
.endif

; --- Console interception ---
; fast_console_flag: runtime toggle (1=fast, 0=native for ANSI.SYS)
; Default set during init, toggled via menu [T] option
FAST_CONSOLE_DEFAULT = 1        ; Compile-time default

; --- Monochrome display color ---
MONO_COLOR      = $05
MONO_REVERSE    = $20 | MONO_COLOR

; --- Screen / debug ---
SECTOR_BUF      = $9800         ; 512-byte sector buffer ($9800-$99FF)
CGA_ROWS        = 25
CGA_COLS        = 80

; --- KERNAL ---
CHROUT          = $FFD2
CHRIN           = $FFCF
SETNAM          = $FFBD
SETLFS          = $FFBA
LOAD            = $FFD5
SETBNK          = $FF6B

; --- VIC-IV registers ---
VIC_KEY         = $D02F         ; VIC-IV unlock register
VIC_CTRL2       = $D031         ; VIC-III control
VIC_HOTREGS     = $D05D         ; VIC-IV hot registers (bit 7 = disable)

; ============================================================================
; Zero Page — 8086 Register File & Decoder State
; ============================================================================
        .include "zeropage.asm"

; ============================================================================
; Entry Point
; ============================================================================
entry:
        ; Enable 40MHz
        lda #65
        sta $00

        ; Unlock MEGA65 VIC-IV mode
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY

        ; Map: $0000–$1FFF = bank 0 ZP/stack
        ;       $6000–$7FFF = bank 0 (emulator code continues)
        ;       $8000–$BFFF = unmapped (reads physical bank 0)
        ; We rely on MAP set at boot; adjust if needed

        lda #147
        jsr CHROUT
        lda #$00
        sta $D020
        sta $D021
        lda #5                  ; White text
        jsr CHROUT

        ; Switch to lowercase character set
        lda #$0E
        jsr CHROUT

+
        ; Clear drive loaded flags
        lda #0
        sta floppy_a_loaded
        sta floppy_b_loaded

        ; Set fast console default (only on cold boot)
        lda #FAST_CONSOLE_DEFAULT
        sta fast_console_flag

        ; Initialize BIOS tables
        jsr init_tables

        ; Load fat_writer module to bank 1 at $13400
        jsr load_fat_writer

        ; Show the disk mount menu (user mounts disks, then selects Start)
        jmp show_menu

; ============================================================================
; start_emulation — Called from menu when user selects "Start Emulation"
; ============================================================================
start_emulation:
        ; Re-unlock VIC-IV (CINT/CHROUT may have re-locked it)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031               ; 40MHz
        lda #$80
        tsb VIC_HOTREGS

        jsr init_guest_mem
        jsr init_cache
        jsr init_regs

        ; Geometry already detected in load_floppy_drive
        jsr init_display

        ; POST beep — short ~1kHz tone via SID
        ; Clear SID registers first
        ldx #$18
_sid_clr:
        lda #0
        sta $D400,x
        dex
        bpl _sid_clr
        ; Set up voice 1
        lda #$0F
        sta $D418               ; Master volume = 15
        lda #$08
        sta $D402               ; Pulse width low
        lda #$08
        sta $D403               ; Pulse width high
        lda #$00
        sta $D405               ; Attack=0, Decay=0
        lda #$F0
        sta $D406               ; Sustain=15, Release=0
        lda #$6E
        sta $D400               ; Frequency low (~2kHz)
        lda #$38
        sta $D401               ; Frequency high
        lda #$41                ; Gate on + pulse waveform
        sta $D404
        ; Wait ~200ms (busy loop, 40MHz = ~40M cycles/sec)
        ldx #0
        ldy #0
        ldz #0
_beep_wait:
        inz
        bne _beep_wait
        iny
        bne _beep_wait
        inx
        cpx #$18
        bne _beep_wait
        ; Gate off
        lda #$40                ; Gate off, pulse waveform
        sta $D404
        ; Silence
        lda #$00
        sta $D418

        ; Load CP437 font into character RAM (before SEI — needs KERNAL)
        jsr load_cp437_font

        ; Print ready message
        ldx #0
-       lda ready_msg,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        ; Now disable IRQs for emulation loop
        sei

        ; Re-init cache & segment state
        jsr init_cache
        lda #1
        sta cs_dirty
        sta ss_dirty
        sta ds_dirty
        lda #0
        sta $8F17
        sta $8F1B               ; Clear interrupt inhibit flag

        ; Clear screen and vidbuf before emulation
        lda #147
        jsr CHROUT
        jsr clear_vidbuf

.if VIDEO_MODE == 7
        lda #30
.else
        lda #15
.endif
        jsr CHROUT
        lda #147
        jsr CHROUT

        ; Initialize sprite cursor
        jsr cursor_init

        ; Enter main emulation loop
        jmp main_loop

ready_msg:
        .text "READY. STARTING EMULATION...", 13, 0

; ============================================================================
; load_cp437_font — Load CP437 font from disk to character RAM at $02A000
; ============================================================================
load_cp437_font:
        ; Disable ROM write-protect for bank 2
        lda #$70
        sta $D640
        clv

        ; Set bank for LOAD: data bank=2, filename bank=0
        lda #$02
        ldx #$00
        jsr SETBNK

        ; Set file parameters: logical #0, device 8, secondary 0
        lda #$00
        ldx #$08
        ldy #$00
        jsr SETLFS

        ; Set filename
        lda #_font_fname_end-_font_fname
        ldx #<_font_fname
        ldy #>_font_fname
        jsr SETNAM

        ; Load to bank 2 at $A000 (linear $02A000)
        lda #$40                ; Force load to X/Y address
        ldx #$00                ; Load address low
        ldy #$A0                ; Load address high ($A000 in bank 2)
        jsr LOAD

        ; Re-unlock VIC-IV (KERNAL LOAD resets it)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031               ; Re-enable 40MHz
        lda #$80
        tsb VIC_HOTREGS

        ; Point VIC-IV character generator to $02A000 (must be after VIC-IV unlock)
        lda #$00
        sta $D068
        lda #$A0
        sta $D069
        lda #$02
        sta $D06A

        rts

_font_fname:
        .text "cp437.bin"
_font_fname_end:

; ============================================================================
; load_fat_writer — Load fat_writer module to bank 1 at $13400
; ============================================================================
load_fat_writer:
        ; Set bank for LOAD: data bank=1, filename bank=0
        lda #$01
        ldx #$00
        jsr SETBNK

        ; Set file parameters: logical #0, device 8, secondary 0
        lda #$00
        ldx #$08
        ldy #$00
        jsr SETLFS

        ; Set filename
        lda #fw_fname_end-fw_fname
        ldx #<fw_fname
        ldy #>fw_fname
        jsr SETNAM

        ; Load to bank 1 at $3400 (linear $13400)
        lda #$40                ; Force load to X/Y address
        ldx #$00                ; Load address low
        ldy #$34                ; Load address high ($3400 in bank 1)
        jsr LOAD

        ; Re-unlock VIC-IV (KERNAL LOAD resets it)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        rts

; ============================================================================
; call_fat_writer — Call fat_writer_test in bank 1 via JSRFAR
; ============================================================================
; JSRFAR ($FF6E) reads target from ZP $02-$05:
;   $02 = bank byte, $03 = addr high, $04 = addr low, $05 = flags/SP
; These overlap 8086 registers (reg_ax, reg_cx) — save/restore them.
;
call_fat_save_floppy:
        ; Copy parameters into fat_writer parameter block in bank 1
        ; Parameter block at $13403 (bank 1, offset $3403)
        ; Set up temp_ptr to point to bank 1 parameter block
        lda #$03
        sta temp_ptr
        lda #$34
        sta temp_ptr+1
        lda #$01
        sta temp_ptr+2
        lda #$00
        sta temp_ptr+3

        ; Write drive number
        lda $8F25
        ldz #0
        sta [temp_ptr],z        ; fw_drive_num

        ; Write geometry for the selected drive
        lda $8F25
        bne _cfsf_drive_b
        ; Drive A
        lda floppy_a_cyls
        ldz #1
        sta [temp_ptr],z        ; fw_cylinders
        lda floppy_a_heads
        ldz #2
        sta [temp_ptr],z        ; fw_heads
        lda floppy_a_spt
        ldz #3
        sta [temp_ptr],z        ; fw_spt
        bra _cfsf_copy_fname
_cfsf_drive_b:
        lda floppy_b_cyls
        ldz #1
        sta [temp_ptr],z
        lda floppy_b_heads
        ldz #2
        sta [temp_ptr],z
        lda floppy_b_spt
        ldz #3
        sta [temp_ptr],z

_cfsf_copy_fname:
        ; Copy filename to fw_filename (offset 4 from param block start)
        ; Advance temp_ptr by 4 to point to fw_filename
        clc
        lda temp_ptr
        adc #4
        sta temp_ptr
        ldx #0
        ldz #0
_cfsf_fname_loop:
        lda floppy_fname_page,x
        sta [temp_ptr],z
        beq _cfsf_fname_done    ; Null terminator copied
        inx
        inz
        cpx #63
        bcc _cfsf_fname_loop
        lda #0
        sta [temp_ptr],z        ; Force null terminate
_cfsf_fname_done:

        ; Save ZP $02-$05 (8086 reg_ax and reg_cx)
        lda $02
        pha
        lda $03
        pha
        lda $04
        pha
        lda $05
        pha

        ; Target: bank 1, address $3400 (jump table entry 0: fat_save_floppy)
        lda #$01                ; Bank 1
        sta $02
        lda #$34                ; Address high
        sta $03
        lda #$00                ; Address low
        sta $04
        lda #$00                ; Flags
        sta $05

        jsr $FF6E               ; JSRFAR

        ; Restore ZP $02-$05
        pla
        sta $05
        pla
        sta $04
        pla
        sta $03
        pla
        sta $02

        ; Convert scratch result to carry flag (JSRFAR doesn't preserve carry)
        lda $8F25
        beq _cfsf_fail
        sec                     ; Success
        rts
_cfsf_fail:
        clc                     ; Failure
        rts

fw_fname:
        .text "ftwriter.bin"
fw_fname_end:

; ============================================================================
; resume_emulation — Called from menu when returning to running emulation
; ============================================================================
resume_emulation:
        ; Load CP437 font BEFORE sei (KERNAL LOAD needs IRQs)
        jsr load_cp437_font

        ; Disable IRQs FIRST to stop KERNAL from trashing ZP
        sei

        ; Restore ZP state from $7F00
        ldx #0
_resume_restore_zp:
        lda $7F00,x
        sta $00,x
        inx
        bne _resume_restore_zp

        ; Re-unlock VIC-IV
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        ; Re-detect geometry (user may have changed disks in menu)
        lda floppy_a_loaded
        beq +
        lda #0
        jsr detect_floppy_geom_drive
+
        ; Restore screen from attic
        jsr menu_restore_screen

        ; Invalidate code cache (menu may have used DMA that changed state)
        lda #CACHE_INVALID
        sta code_cache_pg_lo
        sta code_cache_pg_hi
        ; Note: do NOT call cache_invalidate_all here — it discards dirty
        ; cache lines that contain guest program state, causing the first
        ; command after resume to fail. Disk swap DMA goes to floppy attic
        ; ($8100000+) which is a separate address range from guest RAM cache.

        ; Re-point charset to CP437 (CINT/KERNAL may have reset it)
        lda #$00
        sta $D068
        lda #$A0
        sta $D069
        lda #$02
        sta $D06A

        ; Re-init sprite cursor (CINT trashes VIC-IV sprite state)
        jsr cursor_init
        ; Restore cursor position saved by menu_tab_handler
        lda saved_scr_row
        sta scr_row
        lda saved_scr_col
        sta scr_col
        jsr cursor_update

        ; Resume main loop (segment bases intact from ZP restore)
        jmp main_loop

; ============================================================================
; emulator_exit — Return to MEGA65 prompt
; ============================================================================
emulator_exit:
        cli
        lda #$0D
        jsr CHROUT
        lda #$00
        sta $D610
        rts                     ; Return to BASIC/monitor

; ============================================================================
; Include Modules
; ============================================================================
        .include "mem.asm"      ; Memory API (read/write, seg:ofs mapping)
        .include "cache.asm"    ; Attic RAM cache + DMA helpers
        .include "int.asm"      ; Interrupt handling, push/pop word (needed by decode/opcodes)
        .include "decode.asm"   ; Instruction fetch & decode, main loop
        .include "modrm.asm"    ; ModR/M & effective address calculation
        .include "alu.asm"      ; ALU operations & flags
        .include "opcodes.asm"  ; Opcode handlers
        .include "io.asm"       ; I/O port handlers (IN/OUT, CGA, keyboard)
        .include "disk.asm"     ; Disk I/O (INT 13h, floppy via attic)
        ;.include "fat_writer.asm" ; FAT32 file writer (disabled — will load to bank 1 separately)
        .include "display.asm"  ; CGA refresh, screen output
        .include "init.asm"     ; Initialization (tables, guest mem, regs)
        .include "menu.asm"     ; Disk mount menu system
        .include "tables.asm"   ; Dispatch table, extra_field, parity, etc.