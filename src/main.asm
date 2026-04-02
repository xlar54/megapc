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
VIDEO_EQUIP     = $21           ; Floppy + 80-col CGA
CRTC_PORT       = $03D4         ; CGA CRTC base port
.elsif VIDEO_MODE == 7
VIDEO_EQUIP     = $31           ; Floppy + 80-col monochrome
CRTC_PORT       = $03B4         ; MDA CRTC base port
.endif

; --- Screen / debug ---
SECTOR_BUF      = $9800         ; 512-byte sector buffer ($9800-$99FF)
                                ; (moved from $9600 to avoid 4-line cache at $9200-$95FF)
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

        ; Disable ROM write-protect for bank 2 (used for CGA buffer)
        lda #$70
        sta $D640
        clv

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

        ; Initialize BIOS tables
        jsr init_tables

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
        sta $8FEF

        ; Clear screen before emulation
        lda #147
        jsr CHROUT

.if VIDEO_MODE == 7
        lda #30
.else
        lda #15
.endif
        jsr CHROUT
        lda #147
        jsr CHROUT

        ; Enter main emulation loop
        jmp main_loop

ready_msg:
        .text "READY. STARTING EMULATION...", 13, 0

; ============================================================================
; resume_emulation — Called from menu when returning to running emulation
; ============================================================================
resume_emulation:
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
        .include "display.asm"  ; CGA refresh, screen output
        .include "init.asm"     ; Initialization (tables, guest mem, regs)
        .include "menu.asm"     ; Disk mount menu system
        .include "tables.asm"   ; Dispatch table, extra_field, parity, etc.