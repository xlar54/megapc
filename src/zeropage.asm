; ============================================================================
; zeropage.asm — Zero Page Register & State Definitions
; ============================================================================
;
; $00–$01  Reserved (MEGA65 CPU port)
; $02–$1F  8086 register file (16 registers × 2 bytes = 30 bytes + pad)
; $20–$29  8086 FLAGS (individual bytes for fast access)
; $2A–$2F  (reserved)
; $30–$41  Decoder state
; $42–$5F  Emulator working variables
; $60–$6F  Segment/prefix state
; $70–$8F  32-bit pointers (5 × 4 bytes)
; $90–$9F  Cache state
; $A0–$AF  Counters / debug
; $B0–$BF  Scratch
;
; NOTE: KERNAL IRQ trashes $90–$FA, so we must save/restore if IRQs enabled.
;       Our pointers at $70+ are safe only with IRQs off (SEI).
;       When calling CHROUT (needs IRQs), save $90–$FA first.

; --- 8086 Register File ($02–$1F) ---
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

; --- 8086 FLAGS ($20–$29) ---
; Individual bytes: 0=clear, nonzero=set (fast BNE/BEQ testing)
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

; --- Decoder State ($30–$41) ---
raw_opcode      = $30           ; Current raw 8086 opcode byte
xlat_opcode     = $31           ; Translated handler index
extra_field     = $32           ; Extra field from decode table
i_mod_sz        = $33           ; ModR/M size indicator
set_flags_type  = $34           ; Which flags to set after ALU
i_w             = $35           ; Word mode (0=byte, 1=word)
i_d             = $36           ; Direction (0=reg→rm, 1=rm→reg)
i_reg4bit       = $37           ; 4-bit register from opcode
i_mod           = $38           ; ModR/M mod field (0–3)
i_rm            = $39           ; ModR/M rm field (0–7)
i_reg           = $3A           ; ModR/M reg field (0–7)
i_data0         = $3B           ; Immediate data word 0 (16-bit, $3B–$3C)
i_data1         = $3D           ; Immediate data word 1 (16-bit, $3D–$3E)
i_data2         = $3F           ; Immediate data word 2 (16-bit, $3F–$40)
decode_ip_start = $68           ; IP at start of instruction (for REP, 16-bit $68–$69)

; --- Emulator Working Variables ($42–$5F) ---
reg_ip          = $42           ; 8086 IP (16-bit, $42–$43)
op_source       = $44           ; Source operand (32-bit, $44–$47)
op_dest         = $48           ; Dest operand (32-bit, $48–$4B)
op_result       = $4C           ; ALU result (32-bit, $4C–$4F)
op_to_addr      = $50           ; Destination address (32-bit, $50–$53)
op_from_addr    = $54           ; Source address (32-bit, $54–$57)
rm_addr         = $58           ; Effective address from ModR/M (32-bit, $58–$5B)

; --- Segment/Prefix State ($60–$6F) ---
seg_override_en = $60           ; Nonzero = segment override active
seg_override    = $61           ; Offset from regs base for override segment
rep_override_en = $62           ; Nonzero = REP prefix active
rep_mode        = $63           ; REP mode (0=REPZ, 1=REPNZ)
trap_flag_var   = $64           ; Trap flag latch
int8_asap       = $65           ; Fire INT 8 at next opportunity
advance_ip      = $66           ; 0=don't advance IP (JMP/CALL set this)
disk_sect_left  = $67           ; Sectors remaining for INT 13h read loop

; --- 32-bit Pointers ($70–$8F) ---
; For [ptr],z flat addressing. Byte 3 must be $00 for chip RAM.
; IMPORTANT: stz does NOT work for clearing byte 3 — use lda #$00 / sta
opcode_ptr      = $70           ; CS:IP linear address (4 bytes)
temp_ptr        = $74           ; General purpose pointer (4 bytes)
temp_ptr2       = $78           ; Second pointer (4 bytes)
temp32          = $7C           ; Temp 32-bit value
seg_base        = $80           ; Computed segment base (4 bytes)

; Pre-computed segment bases (avoid recomputing every access)
cs_base         = $84           ; CS base chip address (4 bytes)
ss_base         = $88           ; SS base chip address (4 bytes)
ds_base         = $8C           ; DS base chip address (4 bytes)

; --- Cache State ($90–$9F) ---
; 4-line round-robin cache for attic RAM access
cache_page_hi   = $90           ; 4 bytes: page high (bits 16–19) per line
cache_page_lo   = $94           ; 4 bytes: page low (bits 8–15) per line
cache_dirty     = $98           ; 4 bytes: dirty flag per line
cache_next_line = $9C           ; Round-robin pointer (0–3)
cs_dirty        = $9D           ; CS base needs recompute
ss_dirty        = $9E           ; SS base needs recompute
ds_dirty        = $9F           ; DS base needs recompute

; --- Counters / Debug ($A0–$AF) ---
inst_counter    = $A0           ; Instruction count (16-bit)
tick_counter    = $A2           ; Tick counter for INT 8 timing (16-bit)
unimpl_count    = $A4           ; Count of unimplemented opcodes hit
unimpl_last     = $A5           ; Last unimplemented opcode

; --- Scratch ($B0–$BF) ---
scratch_a       = $B0
scratch_b       = $B1
scratch_c       = $B2
scratch_d       = $B3
ea_offset_lo    = $B4           ; Saved 16-bit EA offset (pre-segment mapping)
ea_offset_hi    = $B5           ; Used by LEA instruction
floppy_loaded   = $B6           ; 1 = floppy image loaded in attic, 0 = not

; Code cache variables (for executing from attic-backed segments)
cs_in_attic     = $B7           ; Non-zero = CS is in attic range, use code cache
cs_base_linear  = $B8           ; 4 bytes: 20-bit unmapped CS linear base ($B8-$BB)
code_cache_pg_lo = $BC          ; Cached code page identifier (bits 8-15 of linear addr)
code_cache_pg_hi = $BD          ; Cached code page identifier (bits 16-19 of linear addr)

; Floppy byte offset for multi-sector disk reads (3 bytes)
floppy_ofs      = $BE           ; 3 bytes: $BE-$C0

; Floppy geometry (detected from BPB at boot) — in non-ZP RAM
; to avoid KERNAL IRQ corruption during init CHROUT calls
floppy_spt      = $8F40         ; Sectors per track
floppy_heads    = $8F41         ; Number of heads
floppy_cyls     = $8F42         ; Number of cylinders
floppy_type     = $8F43         ; BIOS drive type ($01=360K,$02=1.2M,$03=720K,$04=1.44M)

; PUSHA saved SP (2 bytes) — in non-ZP RAM to avoid KERNAL conflicts
pusha_saved_sp  = $8F00         ; 2 bytes

; Division working variables — in non-ZP RAM to avoid KERNAL conflicts
; (KERNAL uses $C1-$CE for screen/keyboard during CHROUT)
div_dividend    = $8F02         ; 4 bytes
div_divisor     = $8F06         ; 2 bytes
div_quotient    = $8F08         ; 4 bytes
div_remainder   = $8F0C         ; 2 bytes
; $B7–$BF availableSTACK_TEMP      = $8FE8         ; 2 bytes: temp buffer for attic stack DMA