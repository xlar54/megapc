; ============================================================================
; Simple OS Shell — minimal command interpreter
; ============================================================================
; Assembled as flat binary, loaded at 0800:0100 by boot sector
; Commands: DIR, ECHO, CLS, VER, and .COM file execution
;
; Disk layout (360K FAT12):
;   Sector 0:     Boot sector
;   Sectors 1-2:  FAT1
;   Sectors 3-4:  FAT2
;   Sectors 5-11: Root directory (112 entries)
;   Sectors 12+:  Data area (cluster 2 = sector 12)

	cpu	8086
	org	0x0100		; Shell is loaded at SHELL_SEG:0100 by boot sector

	jmp	start_code

; ============================================================================
; Buffers — placed at start so they have fixed addresses
; ============================================================================
	align 16
dir_buffer:	times	(7 * 512) db 0		; 3584 bytes for root directory
fat_buffer:	times	(2 * 512) db 0		; 1024 bytes for FAT
batch_buffer:	times	(2 * 512) db 0		; 1024 bytes for batch/FCB I/O
io_buffer:	times	(2 * 512) db 0		; 1024 bytes for handle I/O

; ============================================================================
; Device Driver Chain — built-in character device drivers
; ============================================================================
; Each header: 4 bytes next ptr, 2 bytes attr, 2 bytes strategy,
;              2 bytes interrupt, 8 bytes name = 18 bytes
;
; Driver attribute bits:
;   Bit 15 = 1: character device (0 = block device)
;   Bit 14 = 1: IOCTL supported
;   Bit  3 = 1: clock device
;   Bit  2 = 1: NUL device
;   Bit  1 = 1: standard output (CON)
;   Bit  0 = 1: standard input (CON)

; Request header stored here for driver calls
drv_request:	times 30 db 0
drv_req_ptr:	dw	drv_request	; Strategy saves request pointer here
		dw	0		; Segment (filled at init)

; NUL device — first in chain (always first, per DOS convention)
drv_nul:
	dw	drv_con, 0		; Next = CON (segment filled at init)
	dw	0x8004			; Char device + NUL attribute
	dw	drv_strategy		; Shared strategy routine
	dw	drv_nul_int		; NUL interrupt routine
	db	'NUL     '		; Device name

; CON device — console (keyboard + screen)
drv_con:
	dw	drv_aux, 0		; Next = AUX
	dw	0x8013			; Char device + ISCIN + ISCOT + SPECIAL
	dw	drv_strategy
	dw	drv_con_int
	db	'CON     '

; AUX device — auxiliary (serial port stub)
drv_aux:
	dw	drv_prn, 0		; Next = PRN
	dw	0x8000			; Char device
	dw	drv_strategy
	dw	drv_aux_int
	db	'AUX     '

; PRN device — printer (stub)
drv_prn:
	dw	0xFFFF, 0xFFFF		; Last in chain
	dw	0x8000			; Char device
	dw	drv_strategy
	dw	drv_prn_int
	db	'PRN     '

; Shared strategy routine — just saves the request packet pointer
drv_strategy:
	mov	[cs:drv_req_ptr], bx
	mov	[cs:drv_req_ptr+2], es
	retf

; NUL driver interrupt — discards output, returns EOF on input
drv_nul_int:
	push	bx
	push	es
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	; For reads, set transfer count to 0 (EOF)
	cmp	byte [es:bx+2], 4	; READ command?
	jne	.nul_not_read
	mov	word [es:bx+18], 0	; 0 bytes transferred
.nul_not_read:
	mov	word [es:bx+3], 0x0100	; Status: done, no error
	pop	es
	pop	bx
	retf

; CON driver interrupt — console I/O
drv_con_int:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	es
	push	ds
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	mov	al, [es:bx+2]		; Command code

	cmp	al, 0			; INIT
	je	.con_init
	cmp	al, 4			; READ
	je	.con_read
	cmp	al, 8			; WRITE
	je	.con_write
	cmp	al, 5			; NONDESTRUCTIVE READ
	je	.con_nd_read
	cmp	al, 6			; INPUT STATUS
	je	.con_in_status
	cmp	al, 7			; INPUT FLUSH
	je	.con_in_flush
	cmp	al, 10			; OUTPUT STATUS
	je	.con_out_status
	; Unknown command — return done
	mov	word [es:bx+3], 0x0100
	jmp	.con_done

.con_init:
	mov	word [es:bx+3], 0x0100	; Done
	jmp	.con_done

.con_read:
	; Read CX bytes from keyboard to transfer buffer
	cld
	mov	cx, [es:bx+18]		; Byte count
	mov	di, [es:bx+14]		; Transfer offset
	push	es
	mov	es, [cs:drv_req_ptr+2]
	mov	ds, [es:bx+16]		; Transfer segment
	pop	es
	push	es
	push	ds
	pop	es			; ES:DI = transfer buffer
	xor	dx, dx			; Bytes read
.con_read_loop:
	jcxz	.con_read_done
	mov	ah, 0x00
	int	0x16			; Wait for key
	stosb				; Store in buffer
	dec	cx
	inc	dx
	jmp	.con_read_loop
.con_read_done:
	pop	es
	push	cs
	pop	ds
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	mov	[es:bx+18], dx		; Actual bytes read
	mov	word [es:bx+3], 0x0100	; Done
	jmp	.con_done

.con_write:
	; Write CX bytes from transfer buffer to screen
	cld
	mov	cx, [es:bx+18]		; Byte count
	mov	si, [es:bx+14]		; Transfer offset
	push	ds
	mov	ds, [es:bx+16]		; Transfer segment
	xor	dx, dx			; Bytes written
.con_write_loop:
	jcxz	.con_write_done
	lodsb
	mov	ah, 0x0E
	push	bx
	mov	bx, 0x0007
	int	0x10
	pop	bx
	dec	cx
	inc	dx
	jmp	.con_write_loop
.con_write_done:
	pop	ds
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	mov	[es:bx+18], dx		; Actual bytes written
	mov	word [es:bx+3], 0x0100	; Done
	jmp	.con_done

.con_nd_read:
	; Non-destructive read — check if key available
	mov	ah, 0x01
	int	0x16
	jz	.con_nd_none
	mov	[es:bx+13], al		; Character
	mov	word [es:bx+3], 0x0100	; Done
	jmp	.con_done
.con_nd_none:
	mov	word [es:bx+3], 0x0200	; Busy (no char available)
	jmp	.con_done

.con_in_status:
	mov	ah, 0x01
	int	0x16
	jz	.con_in_not_ready
	mov	word [es:bx+3], 0x0100	; Done (ready)
	jmp	.con_done
.con_in_not_ready:
	mov	word [es:bx+3], 0x0200	; Busy
	jmp	.con_done

.con_in_flush:
	; Flush keyboard buffer
.con_flush_loop:
	mov	ah, 0x01
	int	0x16
	jz	.con_flush_done
	mov	ah, 0x00
	int	0x16
	jmp	.con_flush_loop
.con_flush_done:
	mov	word [es:bx+3], 0x0100
	jmp	.con_done

.con_out_status:
	mov	word [es:bx+3], 0x0100	; Always ready
	jmp	.con_done

.con_done:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	retf

; AUX driver interrupt — stub
drv_aux_int:
	push	bx
	push	es
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	mov	word [es:bx+3], 0x0100	; Done
	mov	word [es:bx+18], 0	; 0 bytes transferred
	pop	es
	pop	bx
	retf

; PRN driver interrupt — stub
drv_prn_int:
	push	bx
	push	es
	mov	es, [cs:drv_req_ptr+2]
	mov	bx, [cs:drv_req_ptr]
	mov	word [es:bx+3], 0x0100	; Done
	mov	word [es:bx+18], 0
	pop	es
	pop	bx
	retf

; ============================================================================
; drv_call — Call a device driver with a prepared request packet
; ============================================================================
; Input: ES:BX = pointer to driver header
;        drv_request must be filled with the request packet
; Output: drv_request status word has the result
drv_call:
	push	ax
	push	bx
	push	cx
	push	di
	push	ds
	push	es
	; Save driver header location
	mov	[cs:drv_call_hdr_off], bx
	mov	[cs:drv_call_hdr_seg], es
	; Set up ES:BX = request packet for strategy
	mov	ax, cs
	mov	es, ax
	mov	bx, drv_request
	; Build far call target for strategy
	push	es			; Save req packet ES
	push	bx			; Save req packet BX
	mov	ds, [cs:drv_call_hdr_seg]
	mov	di, [cs:drv_call_hdr_off]
	mov	ax, [ds:di+6]		; Strategy offset
	mov	[cs:drv_call_target], ax
	mov	ax, ds			; Strategy segment = driver segment
	mov	[cs:drv_call_target+2], ax
	pop	bx
	pop	es
	; Call strategy (ES:BX = request packet)
	call	far [cs:drv_call_target]
	; Build far call target for interrupt
	mov	ds, [cs:drv_call_hdr_seg]
	mov	di, [cs:drv_call_hdr_off]
	mov	ax, [ds:di+8]		; Interrupt offset
	mov	[cs:drv_call_target], ax
	mov	ax, ds
	mov	[cs:drv_call_target+2], ax
	; Call interrupt
	call	far [cs:drv_call_target]
	; Restore
	pop	es
	pop	ds
	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret
drv_call_hdr_off: dw	0
drv_call_hdr_seg: dw	0
drv_call_target: dd	0

; ============================================================================
; drv_find — Find a device driver by name
; ============================================================================
; Input: DS:SI = 8-byte device name (space-padded)
; Output: ES:BX = driver header, CF=0 found / CF=1 not found
drv_find:
	cld
	push	ax
	push	cx
	push	di
	mov	bx, [drv_chain_head]
	mov	es, [drv_chain_head+2]
.df_loop:
	; Check for end of chain
	cmp	bx, 0xFFFF
	jne	.df_check
	cmp	word [es:bx], 0xFFFF
	je	.df_not_found
.df_check:
	; Compare name (8 bytes at header+10)
	push	si
	lea	di, [bx+10]
	mov	cx, 8
	repe	cmpsb
	pop	si
	je	.df_found
	; Next driver
	mov	ax, [es:bx+2]		; Next segment
	mov	bx, [es:bx]		; Next offset
	mov	es, ax
	cmp	bx, 0xFFFF
	jne	.df_loop
	; Check if segment is also FFFF
	mov	ax, es
	cmp	ax, 0xFFFF
	jne	.df_loop
.df_not_found:
	pop	di
	pop	cx
	pop	ax
	stc
	ret
.df_found:
	pop	di
	pop	cx
	pop	ax
	clc
	ret

; ============================================================================
; drv_write_char — Write one character through a device driver
; ============================================================================
; Input: AL = character, ES:BX = driver header
drv_write_char:
	push	ax
	push	cx
	; Store char in a temp buffer
	mov	[cs:drv_char_buf], al
	; Build request packet for WRITE
	mov	byte [cs:drv_request], 22	; Header length
	mov	byte [cs:drv_request+1], 0	; Unit
	mov	byte [cs:drv_request+2], 8	; Command = WRITE
	mov	word [cs:drv_request+3], 0	; Status
	mov	word [cs:drv_request+14], drv_char_buf	; Transfer offset
	mov	word [cs:drv_request+16], cs	; Transfer segment
	mov	word [cs:drv_request+18], 1	; Count = 1 byte
	call	drv_call
	pop	cx
	pop	ax
	ret

drv_char_buf:	db	0

; ============================================================================
; drv_read_char — Read one character from a device driver
; ============================================================================
; Input: ES:BX = driver header
; Output: AL = character read
drv_read_char:
	push	cx
	; Build request packet for READ
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 4	; Command = READ
	mov	word [cs:drv_request+3], 0
	mov	word [cs:drv_request+14], drv_char_buf
	mov	word [cs:drv_request+16], cs
	mov	word [cs:drv_request+18], 1	; Count = 1
	call	drv_call
	mov	al, [cs:drv_char_buf]
	pop	cx
	ret

; ============================================================================
; con_setup_esbx — Load ES:BX to point to current CON driver
; ============================================================================
; Walks the driver chain to find the first driver with ISCIN+ISCOT
; attributes (bits 0+1). This allows a loaded replacement CON driver
; (like ANSI.SYS) to intercept console I/O.
con_setup_esbx:
	; Return cached CON driver pointer (fast path)
	mov	bx, [cs:con_drv_cache_off]
	mov	es, [cs:con_drv_cache_seg]
	ret

; con_find_con — Walk chain to find active CON driver and cache it
; Called once at init and after DEVICE= loads
con_find_con:
	push	ax
	push	bx
	push	es
	mov	bx, [cs:drv_chain_head]
	mov	es, [cs:drv_chain_head+2]
.cfc_loop:
	cmp	bx, 0xFFFF
	je	.cfc_builtin
	mov	ax, [es:bx+4]
	and	ax, 0x0003
	cmp	ax, 0x0003
	je	.cfc_found
	mov	ax, [es:bx+2]
	push	ax
	mov	bx, [es:bx]
	pop	es
	cmp	bx, 0xFFFF
	jne	.cfc_loop
.cfc_builtin:
	mov	bx, drv_con
	mov	ax, cs
	mov	es, ax
.cfc_found:
	mov	[cs:con_drv_cache_off], bx
	mov	[cs:con_drv_cache_seg], es
	pop	es
	pop	bx
	pop	ax
	ret

con_drv_cache_off: dw	drv_con		; Default to built-in
con_drv_cache_seg: dw	0		; Filled at init

; ============================================================================
; con_write_al — Write character in AL through CON driver (preserves all regs)
; ============================================================================
con_write_al:
	; Write char in AL through active CON device driver
	push	bx
	push	cx
	push	es
	mov	[cs:drv_char_buf], al
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 8	; WRITE
	mov	word [cs:drv_request+3], 0
	mov	word [cs:drv_request+14], drv_char_buf
	mov	word [cs:drv_request+16], cs
	mov	word [cs:drv_request+18], 1
	call	con_setup_esbx		; Find active CON driver
	call	drv_call
	pop	es
	pop	cx
	pop	bx
	ret

; ============================================================================
; con_read_al — Read one character from CON driver into AL (preserves other regs)
; ============================================================================
con_read_al:
	; Read one char from active CON device driver into AL
	push	bx
	push	cx
	push	es
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 4	; READ
	mov	word [cs:drv_request+3], 0
	mov	word [cs:drv_request+14], drv_char_buf
	mov	word [cs:drv_request+16], cs
	mov	word [cs:drv_request+18], 1
	call	con_setup_esbx		; Find active CON driver
	call	drv_call
	mov	al, [cs:drv_char_buf]
	pop	es
	pop	cx
	pop	bx
	ret

; ============================================================================
; con_check_input — Non-destructive input check via CON driver
; Returns: ZF=1 if no char available, ZF=0 if char ready (AL = peeked char)
; ============================================================================
con_check_input:
	; Check if key available via active CON driver
	; Returns: ZF=1 no char, ZF=0 char ready
	push	bx
	push	cx
	push	es
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 5	; NONDESTRUCTIVE READ
	mov	word [cs:drv_request+3], 0
	call	con_setup_esbx		; Find active CON driver
	call	drv_call
	; Check busy flag (bit 9 of status word)
	test	word [cs:drv_request+3], 0x0200
	pop	es
	pop	cx
	pop	bx
	jnz	.cci_busy
	; Char available (ZF=0 from the test failing)
	ret
.cci_busy:
	; No char — set ZF
	xor	al, al		; ZF=1
	ret

; Pointer to first driver in chain
drv_chain_head:	dw	drv_nul, 0	; Segment filled at init

start_code:

SHELL_SEG	equ	0x0800	; Segment where shell is loaded
PROG_SEG	equ	0x2000	; Segment where programs are loaded
ROOT_DIR_SEC	equ	5	; First sector of root directory
ROOT_DIR_SECS	equ	7	; Number of root directory sectors
DATA_START_SEC	equ	12	; First data sector (cluster 2)
SECS_PER_CLUST	equ	2	; Sectors per cluster
FAT_SEC		equ	1	; First FAT sector
TOTAL_SECS	equ	720	; Total sectors (360K)
MEDIA_BYTE	equ	0xFD	; 360K floppy media descriptor
MAX_CMD_LEN	equ	127
MAX_DIR_ENTRIES	equ	112	; Root dir entries (subdir = 32 per cluster)
DIR_BUF_SIZE	equ	ROOT_DIR_SECS * 512	; 3584 bytes

; ============================================================================
; Entry point — jump over PSP-like header block
; ============================================================================
start:

; ============================================================================
; Initialization
; ============================================================================
start_init:
	; Set up our own stack
	cli
	mov	ax, SHELL_SEG
	mov	ss, ax
	mov	sp, 0xFFFE
	sti

	; Set DS = CS = SHELL_SEG
	push	cs
	pop	ds

	; Point exec_seg at our PSP (same segment, JFT at offset 0x18)
	mov	word [exec_seg], SHELL_SEG

	; Initialize device driver chain segment pointers and CON cache
	mov	word [drv_nul+2], SHELL_SEG	; NUL → CON segment
	mov	word [drv_con+2], SHELL_SEG	; CON → AUX segment
	mov	word [drv_aux+2], SHELL_SEG	; AUX → PRN segment
	mov	word [drv_chain_head+2], SHELL_SEG
	mov	word [drv_req_ptr+2], SHELL_SEG
	mov	word [con_drv_cache_seg], SHELL_SEG
	call	con_find_con		; Cache the CON driver pointer

	; Install interrupt vectors
	xor	ax, ax
	mov	es, ax
	; INT 20h — program terminate
	mov	word [es:0x80], int20_handler
	mov	word [es:0x82], SHELL_SEG
	; INT 21h — DOS services
	mov	word [es:0x84], int21_handler
	mov	word [es:0x86], SHELL_SEG
	; INT 22h — Terminate address
	mov	word [es:0x88], int20_handler
	mov	word [es:0x8A], SHELL_SEG
	; INT 23h — Ctrl-C handler
	mov	word [es:0x8C], int23_handler
	mov	word [es:0x8E], SHELL_SEG
	; INT 24h — Critical error handler
	mov	word [es:0x90], int24_handler
	mov	word [es:0x92], SHELL_SEG

	; Restore ES = SHELL_SEG
	push	ds
	pop	es

	; Initialize memory management — create MCB chain
	; First MCB at PROG_SEG (0x2000), one large free block
	; Size = (0xA000 - 0x2000 - 1) paragraphs = 0x7FFF paragraphs
	mov	ax, PROG_SEG
	mov	es, ax
	mov	byte [es:0x00], 'Z'	; Last block
	mov	word [es:0x01], 0	; Free (no owner)
	mov	word [es:0x03], 0xA000 - PROG_SEG - 1 ; Size in paragraphs
	mov	word [mcb_first], PROG_SEG

	; Restore ES
	mov	ax, SHELL_SEG
	mov	es, ax

	; Allocate environment block (16 paragraphs = 256 bytes)
	mov	bx, 16
	mov	ah, 0x48
	int	0x21
	jc	.env_failed
	mov	[env_seg], ax
	; Fill environment block
	mov	es, ax
	xor	di, di
	; COMSPEC=A:\SHELL.COM
	mov	si, env_comspec
	call	.env_copy_str
	; PATH=A:\
	mov	si, env_path
	call	.env_copy_str
	; PROMPT=$P$G
	mov	si, env_prompt
	call	.env_copy_str
	; Double null terminates the environment
	mov	byte [es:di], 0
	inc	di
	; Word count (usually 1) + program name
	mov	word [es:di], 1
	add	di, 2
	; Program name ASCIIZ
	mov	si, env_progname
	call	.env_copy_str
	jmp	.env_done
.env_copy_str:
	lodsb
	mov	[es:di], al
	inc	di
	or	al, al
	jnz	.env_copy_str
	ret
.env_failed:
	mov	word [env_seg], 0
.env_done:
	; Allocate a paragraph block for the shell's own PSP
	; We need at least 0x30 bytes (JFT at 0x18, 20 handles)
	; Allocate 4 paragraphs (64 bytes) — plenty for a minimal PSP
	mov	bx, 4
	call	alloc_mem_core
	jc	.psp_failed
	mov	[exec_seg], ax
	mov	[shell_psp_seg], ax
	; Initialize the JFT at PSP:0x18
	mov	es, ax
	; Clear the PSP area
	xor	di, di
	xor	ax, ax
	mov	cx, 32		; 64 bytes / 2
	rep	stosw
	; Set up JFT: handles 0-4 = SFT 0-4, rest = 0xFF
	mov	byte [es:0x18], 0	; stdin
	mov	byte [es:0x19], 1	; stdout
	mov	byte [es:0x1A], 2	; stderr
	mov	byte [es:0x1B], 3	; stdaux
	mov	byte [es:0x1C], 4	; stdprn
	mov	di, 0x1D
	mov	al, 0xFF
	mov	cx, MAX_HANDLES - 5
	rep	stosb
	; PSP:02 = memory top (not critical for shell)
	; PSP:2C = environment segment
	mov	ax, [env_seg]
	mov	[es:0x2C], ax
	jmp	.psp_done
.psp_failed:
	mov	word [exec_seg], 0
.psp_done:

	; Restore ES/DS
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	ds, ax

	; Process CONFIG.SYS if it exists
	call	process_config_sys

	; Run AUTOEXEC.BAT if it exists
	mov	si, autoexec_name
	call	run_batch

; ============================================================================
; Main command loop
; ============================================================================
cmd_loop:
	; Reset segments
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax

	; Restore redirected handles if active
	call	redir_restore

	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti

	; Check if we're in batch mode
	cmp	byte [batch_active], 0
	je	.cmd_interactive
	; Get next line from batch buffer
	jmp	batch_next_line

.cmd_interactive:
	; Print newline before prompt
	mov	al, 0x0D
	mov	ah, 0x0E
	int	0x10
	mov	al, 0x0A
	mov	ah, 0x0E
	int	0x10
	; Find PROMPT= in environment
	push	es
	mov	es, [env_seg]
	xor	si, si
.prompt_scan:
	cmp	byte [es:si], 0		; End of env
	je	.prompt_default
	; Check for "PROMPT="
	cmp	byte [es:si], 'P'
	jne	.prompt_skip
	cmp	byte [es:si+1], 'R'
	jne	.prompt_skip
	cmp	byte [es:si+2], 'O'
	jne	.prompt_skip
	cmp	byte [es:si+3], 'M'
	jne	.prompt_skip
	cmp	byte [es:si+4], 'P'
	jne	.prompt_skip
	cmp	byte [es:si+5], 'T'
	jne	.prompt_skip
	cmp	byte [es:si+6], '='
	jne	.prompt_skip
	; Found — SI+7 points to format string
	add	si, 7
	jmp	.prompt_interpret
.prompt_skip:
	; Advance past this env string
	cmp	byte [es:si], 0
	je	.prompt_skip_next
	inc	si
	jmp	.prompt_skip
.prompt_skip_next:
	inc	si
	jmp	.prompt_scan
.prompt_default:
	; No PROMPT in env — use $P$G
	pop	es
	; Hardcoded fallback
	mov	al, [cur_drive]
	add	al, 'A'
	mov	ah, 0x0E
	int	0x10
	mov	al, ':'
	mov	ah, 0x0E
	int	0x10
	mov	al, '\'
	mov	ah, 0x0E
	int	0x10
	cmp	byte [cur_dir_pathlen], 0
	je	.prompt_fb_done
	push	si
	mov	si, cur_dir_path
	call	print_string
	pop	si
.prompt_fb_done:
	mov	al, '>'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_done

.prompt_interpret:
	; ES:SI = PROMPT format string in environment
	mov	al, [es:si]
	or	al, al
	jz	.prompt_interp_done
	inc	si
	cmp	al, '$'
	je	.prompt_dollar
	; Regular character — print it
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret
.prompt_dollar:
	mov	al, [es:si]
	or	al, al
	jz	.prompt_interp_done
	inc	si
	; Uppercase the code
	cmp	al, 'a'
	jb	.prompt_code
	cmp	al, 'z'
	ja	.prompt_code
	sub	al, 0x20
.prompt_code:
	cmp	al, 'P'
	je	.prompt_path
	cmp	al, 'G'
	je	.prompt_gt
	cmp	al, 'L'
	je	.prompt_lt
	cmp	al, 'N'
	je	.prompt_drive
	cmp	al, 'D'
	je	.prompt_date
	cmp	al, 'T'
	je	.prompt_time
	cmp	al, 'V'
	je	.prompt_version
	cmp	al, 'B'
	je	.prompt_pipe
	cmp	al, 'Q'
	je	.prompt_eq
	cmp	al, 'E'
	je	.prompt_esc
	cmp	al, 'H'
	je	.prompt_bs
	cmp	al, '$'
	je	.prompt_dollar_lit
	cmp	al, '_'
	je	.prompt_crlf
	; Unknown code — print $ and the char
	push	ax
	mov	al, '$'
	mov	ah, 0x0E
	int	0x10
	pop	ax
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_path:
	; $P — current drive and path
	push	si
	push	es
	mov	al, [cur_drive]
	add	al, 'A'
	mov	ah, 0x0E
	int	0x10
	mov	al, ':'
	mov	ah, 0x0E
	int	0x10
	mov	al, '\'
	mov	ah, 0x0E
	int	0x10
	cmp	byte [cur_dir_pathlen], 0
	je	.prompt_path_done
	mov	si, cur_dir_path
	call	print_string
.prompt_path_done:
	pop	es
	pop	si
	jmp	.prompt_interpret

.prompt_gt:
	mov	al, '>'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_lt:
	mov	al, '<'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_drive:
	mov	al, [cur_drive]
	add	al, 'A'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_date:
	push	si
	push	es
	push	cx
	push	dx
	mov	ah, 0x2A
	int	0x21
	mov	al, dh
	call	do_date.print_2dig
	mov	al, '-'
	mov	ah, 0x0E
	int	0x10
	mov	al, dl
	call	do_date.print_2dig
	mov	al, '-'
	mov	ah, 0x0E
	int	0x10
	mov	ax, cx
	call	do_date.print_year
	pop	dx
	pop	cx
	pop	es
	pop	si
	jmp	.prompt_interpret

.prompt_time:
	push	si
	push	es
	push	cx
	push	dx
	mov	ah, 0x2C
	int	0x21
	mov	al, ch
	call	do_date.print_2dig
	mov	al, ':'
	mov	ah, 0x0E
	int	0x10
	mov	al, cl
	call	do_date.print_2dig
	mov	al, ':'
	mov	ah, 0x0E
	int	0x10
	mov	al, dh
	call	do_date.print_2dig
	pop	dx
	pop	cx
	pop	es
	pop	si
	jmp	.prompt_interpret

.prompt_version:
	push	si
	push	es
	mov	si, .prompt_ver_str
	call	print_string
	pop	es
	pop	si
	jmp	.prompt_interpret
.prompt_ver_str: db	'MegaDOS 3.0', 0

.prompt_pipe:
	mov	al, '|'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_eq:
	mov	al, '='
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_esc:
	mov	al, 27
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_bs:
	mov	al, 8
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_dollar_lit:
	mov	al, '$'
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_crlf:
	mov	al, 0x0D
	mov	ah, 0x0E
	int	0x10
	mov	al, 0x0A
	mov	ah, 0x0E
	int	0x10
	jmp	.prompt_interpret

.prompt_interp_done:
	pop	es
.prompt_done:

	; Read command line via INT 21h AH=0A (enables DOSKEY hook)
	mov	byte [input_buf], MAX_CMD_LEN
	mov	byte [input_buf+1], 0
	mov	ah, 0x0A
	mov	dx, input_buf
	int	0x21
	; Print newline after input
	mov	al, 0x0D
	mov	ah, 0x0E
	int	0x10
	mov	al, 0x0A
	mov	ah, 0x0E
	int	0x10
	; Copy input to cmd_buffer and null-terminate
	mov	si, input_buf + 2
	mov	di, cmd_buffer
	xor	ch, ch
	mov	cl, [input_buf+1]	; Actual length
	jcxz	.input_empty
	rep	movsb
.input_empty:
	mov	byte [di], 0

	; Parse and set up I/O redirection before dispatch
	call	redir_parse

	; Skip leading spaces
	mov	si, cmd_buffer
	call	skip_spaces

	; Empty line?
	cmp	byte [si], 0
	je	cmd_loop

	; Activate redirection (open files, redirect handles)
	; AH=3Ch inside redir_activate overwrites cmd_buffer, so save it first
	push	si
	push	di
	push	cx
	mov	si, cmd_buffer
	mov	di, redir_cmd_save
	mov	cx, MAX_CMD_LEN + 1
	rep	movsb
	pop	cx
	pop	di
	pop	si
	call	redir_activate
	; Restore cmd_buffer
	push	si
	push	di
	push	cx
	mov	si, redir_cmd_save
	mov	di, cmd_buffer
	mov	cx, MAX_CMD_LEN + 1
	rep	movsb
	pop	cx
	pop	di
	pop	si
	; Re-parse SI from restored cmd_buffer
	mov	si, cmd_buffer
	call	skip_spaces

cmd_dispatch:
	; Check for built-in commands
	mov	di, cmd_dir
	call	str_compare_cmd
	je	do_dir

	mov	di, cmd_echo
	call	str_compare_cmd
	je	do_echo

	mov	di, cmd_cls
	call	str_compare_cmd
	je	do_cls

	mov	di, cmd_ver
	call	str_compare_cmd
	je	do_ver

	mov	di, cmd_type
	call	str_compare_cmd
	je	do_type

	mov	di, cmd_del
	call	str_compare_cmd
	je	do_del

	mov	di, cmd_ren
	call	str_compare_cmd
	je	do_ren

	mov	di, cmd_copy
	call	str_compare_cmd
	je	do_copy

	mov	di, cmd_cd
	call	str_compare_cmd
	je	do_cd

	mov	di, cmd_mkdir
	call	str_compare_cmd
	je	do_mkdir

	mov	di, cmd_rmdir
	call	str_compare_cmd
	je	do_rmdir

	mov	di, cmd_set
	call	str_compare_cmd
	je	do_set

	mov	di, cmd_prompt
	call	str_compare_cmd
	je	do_prompt

	mov	di, cmd_path
	call	str_compare_cmd
	je	do_path

	mov	di, cmd_date
	call	str_compare_cmd
	je	do_date

	mov	di, cmd_time
	call	str_compare_cmd
	je	do_time

	; Check for drive switch (A: or B:)
	mov	si, cmd_buffer
	call	skip_spaces
	cmp	byte [si+1], ':'
	jne	.not_drive_switch
	cmp	byte [si+2], 0
	je	.maybe_drive
	cmp	byte [si+2], ' '
	je	.maybe_drive
	jmp	.not_drive_switch
.maybe_drive:
	mov	al, [si]
	cmp	al, 'a'
	jb	.check_upper_drv
	cmp	al, 'z'
	ja	.not_drive_switch
	sub	al, 0x20
.check_upper_drv:
	cmp	al, 'A'
	je	.switch_a
	cmp	al, 'B'
	je	.switch_b
	jmp	.not_drive_switch
.switch_a:
	call	save_drive_state	; Save current drive's state
	mov	byte [cur_drive], 0
	mov	al, 0
	call	load_drive_state	; Load drive A's state
	jmp	cmd_loop
.switch_b:
	call	save_drive_state	; Save current drive's state
	mov	byte [cur_drive], 1
	mov	al, 1
	call	load_drive_state	; Load drive B's state
	jmp	cmd_loop
.not_drive_switch:

	; Not a built-in — check for .BAT file first, then try .COM
	; Check if the command has .BAT extension
	mov	si, cmd_buffer
	call	skip_spaces
	push	si
	; Scan for ".BAT" or ".bat"
	mov	di, si
.check_bat_ext:
	mov	al, [di]
	cmp	al, 0
	je	.not_bat
	cmp	al, ' '
	je	.not_bat
	cmp	al, '.'
	je	.found_dot
	inc	di
	jmp	.check_bat_ext
.found_dot:
	; Check if extension is BAT
	inc	di
	mov	al, [di]
	cmp	al, 'B'
	je	.dot_b
	cmp	al, 'b'
	je	.dot_b
	jmp	.not_bat
.dot_b:
	inc	di
	mov	al, [di]
	cmp	al, 'A'
	je	.dot_ba
	cmp	al, 'a'
	je	.dot_ba
	jmp	.not_bat
.dot_ba:
	inc	di
	mov	al, [di]
	cmp	al, 'T'
	je	.is_bat
	cmp	al, 't'
	je	.is_bat
	jmp	.not_bat
.is_bat:
	pop	si
	call	run_batch
	jmp	cmd_loop
.not_bat:
	pop	si
	jmp	do_exec

; ============================================================================
; DIR — list root directory
; ============================================================================
do_dir:
	; Check for /W switch
	mov	byte [dir_wide], 0
	call	skip_spaces
	cmp	byte [si], '/'
	jne	.dir_no_switch
	cmp	byte [si+1], 'W'
	je	.dir_set_wide
	cmp	byte [si+1], 'w'
	je	.dir_set_wide
	jmp	.dir_no_switch
.dir_set_wide:
	mov	byte [dir_wide], 1
	add	si, 2
	call	skip_spaces
.dir_no_switch:
	mov	byte [wild_active], 0

	; Check for optional path argument
	cmp	byte [si], 0
	je	.dir_cur		; No argument — use current directory

	; Build header path by resolving the argument against cur_dir_path
	; Start with a copy of cur_dir_path, then apply each component
	push	si

	; Copy cur_dir_path to dir_hdr_path as starting point
	push	si
	mov	si, cur_dir_path
	mov	di, dir_hdr_path
.dir_hdr_init:
	lodsb
	stosb
	or	al, al
	jnz	.dir_hdr_init
	pop	si

	; Skip drive letter if present
	cmp	byte [si+1], ':'
	jne	.dir_hdr_no_drv
	add	si, 2
.dir_hdr_no_drv:
	; Check for absolute path
	cmp	byte [si], '\'
	jne	.dir_hdr_components
	inc	si
	; Absolute — clear header path
	mov	byte [dir_hdr_path], 0

.dir_hdr_components:
	; Process each component
	cmp	byte [si], 0
	je	.dir_hdr_final
	cmp	byte [si], ' '
	je	.dir_hdr_final

	; Check for ".."
	cmp	byte [si], '.'
	jne	.dir_hdr_name
	cmp	byte [si+1], '.'
	jne	.dir_hdr_check_dot
	; Verify ".." ends with \, null, or space
	cmp	byte [si+2], '\'
	je	.dir_hdr_dotdot
	cmp	byte [si+2], 0
	je	.dir_hdr_dotdot
	cmp	byte [si+2], ' '
	je	.dir_hdr_dotdot
	jmp	.dir_hdr_name
.dir_hdr_check_dot:
	; Single "."
	cmp	byte [si+1], '\'
	je	.dir_hdr_skipdot
	cmp	byte [si+1], 0
	je	.dir_hdr_final
	cmp	byte [si+1], ' '
	je	.dir_hdr_final
	jmp	.dir_hdr_name
.dir_hdr_skipdot:
	add	si, 2			; skip ".\"
	jmp	.dir_hdr_components

.dir_hdr_dotdot:
	; Remove last component from dir_hdr_path
	push	si
	mov	di, dir_hdr_path
	; Find end
	mov	si, di
.dir_hdr_dd_end:
	cmp	byte [si], 0
	je	.dir_hdr_dd_scan
	inc	si
	jmp	.dir_hdr_dd_end
.dir_hdr_dd_scan:
	dec	si
	cmp	si, di
	jb	.dir_hdr_dd_root
	cmp	byte [si], '\'
	je	.dir_hdr_dd_trunc
	jmp	.dir_hdr_dd_scan
.dir_hdr_dd_trunc:
	mov	byte [si], 0
	jmp	.dir_hdr_dd_done
.dir_hdr_dd_root:
	mov	byte [dir_hdr_path], 0
.dir_hdr_dd_done:
	pop	si
	add	si, 2			; skip ".."
	cmp	byte [si], '\'
	jne	.dir_hdr_components
	inc	si			; skip trailing '\'
	jmp	.dir_hdr_components

.dir_hdr_name:
	; Append this component to dir_hdr_path
	mov	di, dir_hdr_path
.dir_hdr_find_end:
	cmp	byte [di], 0
	je	.dir_hdr_at_end
	inc	di
	jmp	.dir_hdr_find_end
.dir_hdr_at_end:
	; Add separator if path not empty
	cmp	di, dir_hdr_path
	je	.dir_hdr_append
	mov	byte [di], '\'
	inc	di
.dir_hdr_append:
	; Bounds check: don't write past dir_hdr_path + 63
	cmp	di, dir_hdr_path + 63
	jae	.dir_hdr_comp_done
	mov	al, [si]
	cmp	al, 0
	je	.dir_hdr_comp_done
	cmp	al, ' '
	je	.dir_hdr_comp_done
	cmp	al, '\'
	je	.dir_hdr_comp_sep
	cmp	al, 'a'
	jb	.dir_hdr_app_store
	cmp	al, 'z'
	ja	.dir_hdr_app_store
	sub	al, 0x20
.dir_hdr_app_store:
	mov	[di], al
	inc	si
	inc	di
	jmp	.dir_hdr_append
.dir_hdr_comp_sep:
	mov	byte [di], 0
	inc	si			; skip '\'
	jmp	.dir_hdr_components
.dir_hdr_comp_done:
	mov	byte [di], 0

.dir_hdr_final:
	pop	si

	; Check if the argument contains wildcards (* or ?)
	push	si
	mov	byte [.dir_has_wild], 0
.dir_scan_wild:
	mov	al, [si]
	cmp	al, 0
	je	.dir_scan_done
	cmp	al, '*'
	je	.dir_found_wild
	cmp	al, '?'
	je	.dir_found_wild
	inc	si
	jmp	.dir_scan_wild
.dir_found_wild:
	mov	byte [.dir_has_wild], 1
.dir_scan_done:
	pop	si

	; Header path already truncated at last separator above

	cmp	byte [.dir_has_wild], 1
	je	.dir_wildcard

	; No wildcards — resolve as path
	call	resolve_path
	jc	.dir_error

	; Check if exec_fname is blank (path ended with \ or was just a drive)
	; If so, list that directory. If not, the last component is a name —
	; check if it's a directory and list it.
	cmp	byte [exec_fname], ' '
	je	.dir_resolved		; Blank name = list resolved dir

	; exec_fname has a name — look it up, see if it's a directory
	call	read_resolved_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.dir_find_subdir:
	mov	al, [si]
	cmp	al, 0
	je	.dir_not_subdir		; Not found as subdir — try as filename filter
	cmp	al, 0xE5
	je	.dir_find_next
	test	byte [si+11], 0x10	; Directory?
	jz	.dir_find_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.dir_found_subdir
.dir_find_next:
	add	si, 32
	dec	cx
	jnz	.dir_find_subdir

.dir_not_subdir:
	; Not a directory — treat exec_fname as exact filename filter
	; Strip filename from header path (keep only directory portion)
	call	.dir_hdr_strip_last
	mov	si, exec_fname
	mov	di, wild_pattern
	mov	cx, 11
	rep	movsb
	mov	byte [wild_active], 1
	; dir_buffer still has the resolved directory data
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.dir_start

.dir_found_subdir:
	; Update resolved to point into this subdirectory
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.dir_is_sub
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.dir_resolved
.dir_is_sub:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
	jmp	.dir_resolved

.dir_wildcard:
	; Strip wildcard filename from header path
	call	.dir_hdr_strip_last
	; Parse wildcard pattern from the filename portion
	; Find the last \ or : to split directory from pattern
	push	si
	mov	di, si		; DI = start of arg
	xor	bx, bx		; BX = pointer to last separator (0=none)
.dir_w_find_sep:
	mov	al, [si]
	cmp	al, 0
	je	.dir_w_sep_done
	cmp	al, '\'
	je	.dir_w_mark_sep
	cmp	al, ':'
	je	.dir_w_mark_sep
	inc	si
	jmp	.dir_w_find_sep
.dir_w_mark_sep:
	lea	bx, [si+1]	; BX = char after separator
	inc	si
	jmp	.dir_w_find_sep
.dir_w_sep_done:
	pop	si

	; BX = start of filename pattern (or 0 if no separator)
	cmp	bx, 0
	jne	.dir_w_has_dir
	; No directory part — wildcard is the whole argument
	mov	bx, si		; pattern starts at SI
	push	si
	mov	di, wild_pattern
	call	parse_wildcard
	pop	si
	jmp	.dir_cur_wild

.dir_w_has_dir:
	; Parse the wildcard pattern from BX
	push	si
	mov	si, bx
	mov	di, wild_pattern
	call	parse_wildcard
	pop	si

	; Temporarily terminate string at the separator for resolve_path
	mov	al, [bx-1]
	push	ax		; Save original separator byte
	mov	byte [bx-1], 0
	call	resolve_path
	pop	ax
	mov	[bx-1], al	; Restore separator

	jc	.dir_error
	cmp	byte [exec_fname], ' '
	je	.dir_resolved_wild
	; The directory part might point to a subdir — look it up
	call	read_resolved_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.dir_find_subdir_wild
.dir_find_subdir_wild:
	mov	al, [si]
	cmp	al, 0
	je	.dir_error
	cmp	al, 0xE5
	je	.dir_find_next_wild
	test	byte [si+11], 0x10
	jz	.dir_find_next_wild
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.dir_found_subdir_wild
.dir_find_next_wild:
	add	si, 32
	dec	cx
	jnz	.dir_find_subdir_wild
	jmp	.dir_error
.dir_found_subdir_wild:
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.dir_is_sub_wild
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.dir_resolved_wild
.dir_is_sub_wild:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32

.dir_resolved_wild:
	call	read_resolved_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.dir_start

.dir_cur_wild:
	; Current dir + wildcard
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	call	read_cur_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [cur_dir_entries]
	jmp	.dir_start

.dir_has_wild:	db	0

; Strip last component from dir_hdr_path (remove filename, keep directory)
.dir_hdr_strip_last:
	push	si
	push	di
	mov	si, dir_hdr_path
	xor	di, di			; DI = position of last '\'
.dir_hdr_sl:
	cmp	byte [si], 0
	je	.dir_hdr_sl_done
	cmp	byte [si], '\'
	jne	.dir_hdr_sl_next
	mov	di, si
.dir_hdr_sl_next:
	inc	si
	jmp	.dir_hdr_sl
.dir_hdr_sl_done:
	cmp	di, 0
	je	.dir_hdr_sl_clear	; No '\' — entire path is the filename
	mov	byte [di], 0		; Truncate at last '\'
	jmp	.dir_hdr_sl_ret
.dir_hdr_sl_clear:
	mov	byte [dir_hdr_path], 0
.dir_hdr_sl_ret:
	pop	di
	pop	si
	ret

.dir_resolved:
	; Read the resolved directory
	call	read_resolved_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.dir_start

.dir_cur:
	; No argument — read current directory
	; Set resolved_drive to cur_drive for read_cur_dir
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	; Copy cur_dir_path to dir_hdr_path
	push	si
	mov	si, cur_dir_path
	mov	di, dir_hdr_path
.dir_cur_cp:
	lodsb
	stosb
	or	al, al
	jnz	.dir_cur_cp
	pop	si
	call	read_cur_dir
	jc	.dir_error
	mov	si, dir_buffer
	mov	cx, [cur_dir_entries]

.dir_start:
	mov	word [file_count], 0
	mov	byte [dir_col], 0

	; Print volume header — scan for volume label entry
	call	shell_crlf
	push	si
	push	cx
	mov	si, dir_buffer
.vol_scan:
	cmp	byte [si], 0		; End of directory
	je	.vol_none
	cmp	byte [si], 0xE5		; Deleted
	je	.vol_scan_next
	test	byte [si+11], 0x08	; Volume label attribute?
	jnz	.vol_found
.vol_scan_next:
	add	si, 32
	dec	cx
	jnz	.vol_scan
.vol_none:
	pop	cx
	pop	si
	push	si
	mov	si, msg_vol_hdr
	call	print_string
	pop	si
	jmp	.vol_hdr_done
.vol_found:
	pop	cx
	; Print " Volume in drive is "
	push	si
	mov	si, msg_vol_is
	call	print_string
	pop	si
	; Print the 11-char label
	mov	cx, 11
.vol_print:
	lodsb
	call	shell_putc
	dec	cx
	jnz	.vol_print
	call	shell_crlf
	pop	si
.vol_hdr_done:
	; Print "Directory of  X:\"
	push	si
	mov	si, msg_dir_of
	call	print_string
	mov	al, [resolved_drive]
	add	al, 'A'
	call	shell_putc
	mov	al, ':'
	call	shell_putc
	mov	al, '\'
	call	shell_putc
	cmp	byte [dir_hdr_path], 0
	je	.dir_hdr_no_path
	mov	si, dir_hdr_path
	call	print_string
.dir_hdr_no_path:
	call	shell_crlf
	call	shell_crlf
	pop	si

.dir_entry:
	; Check first byte
	mov	al, [si]
	cmp	al, 0x00		; End of directory
	je	.dir_done
	cmp	al, 0xE5		; Deleted entry
	je	.dir_next
	; Check attribute byte for volume label
	mov	al, [si+11]
	test	al, 0x08		; Volume label?
	jnz	.dir_next

	; Wildcard filter
	cmp	byte [wild_active], 0
	je	.dir_no_filter
	push	si
	mov	di, wild_pattern
	call	match_wildcard
	pop	si
	jc	.dir_next		; No match — skip
.dir_no_filter:

	push	cx
	push	si

	; Check wide mode
	cmp	byte [dir_wide], 1
	je	.dir_wide_entry

	; === Normal mode ===
	; Print filename (8 chars, space-padded)
	mov	cx, 8
.print_name:
	mov	al, [si]
	call	shell_putc
	inc	si
	dec	cx
	jnz	.print_name
	; Space separator
	mov	al, ' '
	call	shell_putc
	; Print extension (3 chars)
	mov	cx, 3
.print_ext:
	mov	al, [si]
	call	shell_putc
	inc	si
	dec	cx
	jnz	.print_ext

	; Check if directory
	pop	si
	push	si
	test	byte [si+11], 0x10
	jnz	.dir_show_dir

	; Print file size (right-aligned in 10 chars)
	mov	ax, [si+28]
	mov	dx, [si+30]
	call	print_size_padded
	; Three spaces after size
	mov	al, ' '
	call	shell_putc
	call	shell_putc
	call	shell_putc
	jmp	.dir_print_date

.dir_show_dir:
	push	si
	mov	si, msg_dir_tag_fmt
	call	print_string
	pop	si

.dir_print_date:
	pop	si
	push	si
	mov	ax, [si+24]
	or	ax, ax
	jz	.dir_no_date
	; Month
	push	ax
	mov	cl, 5
	shr	ax, cl
	and	ax, 0x0F
	call	print_2digit_space
	mov	al, '-'
	call	shell_putc
	; Day
	pop	ax
	push	ax
	and	ax, 0x1F
	call	print_2digit
	mov	al, '-'
	call	shell_putc
	; Year
	pop	ax
	mov	cl, 9
	shr	ax, cl
	add	ax, 80
	cmp	ax, 100
	jb	.dir_yr_ok
	sub	ax, 100
.dir_yr_ok:
	call	print_2digit
	; Two spaces
	mov	al, ' '
	call	shell_putc
	call	shell_putc
	; Time
	pop	si
	push	si
	mov	ax, [si+22]
	or	ax, ax
	jz	.dir_no_time
	push	ax
	mov	cl, 11
	shr	ax, cl
	mov	bl, 'a'
	cmp	ax, 12
	jb	.dir_am
	mov	bl, 'p'
	cmp	ax, 12
	je	.dir_am
	sub	ax, 12
.dir_am:
	cmp	ax, 0
	jne	.dir_hr_ok
	mov	ax, 12
.dir_hr_ok:
	call	print_2digit_space
	mov	al, ':'
	call	shell_putc
	pop	ax
	mov	cl, 5
	shr	ax, cl
	and	ax, 0x3F
	call	print_2digit
	mov	al, bl
	call	shell_putc
	jmp	.dir_end_line
.dir_no_date:
.dir_no_time:
.dir_end_line:
	call	shell_crlf
	pop	si
	pop	cx
	inc	word [file_count]
	jmp	.dir_next_line

	; === Wide mode ===
.dir_wide_entry:
	; Print filename (8 chars, trimmed) + space + ext (3 chars)
	; Each entry is 16 chars wide, 5 per row
	mov	cx, 8
.dir_w_name:
	mov	al, [si]
	call	shell_putc
	inc	si
	dec	cx
	jnz	.dir_w_name
	; Space
	mov	al, ' '
	call	shell_putc
	; Extension
	mov	cx, 3
.dir_w_ext:
	mov	al, [si]
	call	shell_putc
	inc	si
	dec	cx
	jnz	.dir_w_ext
	; Padding spaces to fill 16 chars (8+1+3=12, need 4 more)
	mov	cx, 4
.dir_w_pad:
	mov	al, ' '
	call	shell_putc
	dec	cx
	jnz	.dir_w_pad

	; Column tracking
	inc	byte [dir_col]
	cmp	byte [dir_col], 5
	jb	.dir_w_no_newline
	mov	byte [dir_col], 0
.dir_w_no_newline:
	pop	si
	pop	cx
	inc	word [file_count]
	jmp	.dir_next_line

.dir_next:
	add	si, 32
	dec	cx
	jnz	.dir_entry
	jmp	.dir_done

.dir_next_line:
	add	si, 32
	dec	cx
	jnz	.dir_entry

.dir_done:
	; If no files matched and a filter was active, show "File not found"
	cmp	byte [wild_active], 0
	je	.dir_done_wide_check
	cmp	word [file_count], 0
	jne	.dir_done_wide_check
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.dir_done_wide_check:
	; If wide mode and not at column 0, add newline
	cmp	byte [dir_wide], 0
	je	.dir_done_summary
	cmp	byte [dir_col], 0
	je	.dir_done_summary
	call	shell_crlf
.dir_done_summary:
	; Print summary
	mov	ax, [file_count]
	xor	dx, dx
	mov	cx, 9
	call	print_rpad_dec
	mov	si, msg_files_fmt
	call	print_string

	; Calculate free space: count free clusters in FAT
	; Use resolved_drive for the correct disk
	call	read_fat
	jc	.dir_no_free
	xor	bx, bx			; Free cluster count
	mov	ax, 2			; Start at cluster 2
	; Get total clusters from BPB: (total_sectors - data_start) / secs_per_clust
	; For 360K: (720 - 12) / 2 = 354 clusters
	mov	cx, 354			; Max data clusters for 360K
	add	cx, 2			; Clusters start at 2
.dir_count_free:
	cmp	ax, cx
	jae	.dir_free_done
	push	ax
	push	cx
	call	fat12_read_cluster
	cmp	ax, 0
	pop	cx
	pop	ax
	jne	.dir_not_free
	inc	bx
.dir_not_free:
	inc	ax
	jmp	.dir_count_free
.dir_free_done:
	; Free bytes = free_clusters * SECS_PER_CLUST * 512
	mov	ax, bx
	mov	cx, SECS_PER_CLUST * 512
	mul	cx			; DX:AX = free bytes
	call	print_decimal_32
	mov	si, msg_bytes_free
	call	print_string
	call	shell_crlf
	jmp	cmd_loop
.dir_no_free:
	call	shell_crlf
	jmp	cmd_loop

.dir_error:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; ECHO — print rest of command line
; ============================================================================
do_echo:
	; SI points past "ECHO" — skip the space after it
	call	skip_spaces
	call	print_string
	; Print newline
	call	shell_crlf
	jmp	cmd_loop

; ============================================================================
; CLS — clear screen
; ============================================================================
do_cls:
	mov	ah, 0x06
	mov	al, 0x00
	mov	bh, 0x07
	mov	cx, 0x0000
	mov	dx, 0x184F
	int	0x10
	; Home cursor
	mov	ah, 0x02
	mov	bh, 0
	mov	dx, 0x0000
	int	0x10
	jmp	cmd_loop

; ============================================================================
; VER — show version
; ============================================================================
do_ver:
	mov	si, msg_ver
	call	print_string
	jmp	cmd_loop

; ============================================================================
; TYPE — display file contents
; ============================================================================
do_type:
	; SI points past "TYPE" — skip spaces to get filename
	call	skip_spaces
	cmp	byte [si], 0
	jne	.type_has_name
	mov	si, msg_need_fname
	call	print_string
	jmp	cmd_loop

.type_has_name:
	; Resolve path (handles DIR\FILE.TXT, \DIR\FILE, FILE.TXT)
	call	resolve_path
	jc	.type_not_found

	; Read resolved directory
	call	read_resolved_dir
	jc	.type_disk_err

	; Search for file
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.type_search:
	mov	al, [si]
	cmp	al, 0x00
	je	.type_not_found
	cmp	al, 0xE5
	je	.type_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.type_found
.type_search_next:
	add	si, 32
	dec	cx
	jnz	.type_search

.type_not_found:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.type_found:
	; Get starting cluster and file size
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	mov	ax, [si+28]
	mov	[exec_size], ax
	mov	ax, [si+30]
	mov	[exec_size+2], ax

	; Load FAT
	call	read_fat
	jc	.type_disk_err

	; Read and print file cluster by cluster
	mov	ax, [exec_cluster]

.type_read_cluster:
	; Convert cluster to sector
	push	ax
	sub	ax, 2
	mov	cx, SECS_PER_CLUST
	mul	cx
	add	ax, DATA_START_SEC

	; Convert linear sector to CHS
	; Save sector number, compute CHS
	xor	dx, dx
	mov	cx, 18			; SPT * heads
	div	cx			; AX = cylinder, DX = remainder
	push	ax			; Save cylinder
	mov	ax, dx
	xor	dx, dx
	mov	cx, 9			; SPT
	div	cx			; AX = head, DX = sector (0-based)
	mov	dh, al			; DH = head
	mov	cl, dl
	inc	cl			; CL = sector (1-based)
	pop	ax
	mov	ch, al			; CH = cylinder

	; Read cluster into dir_buffer (reuse as temp)
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	jc	.type_disk_err_pop

	; Print bytes from buffer, up to file size remaining
	mov	si, dir_buffer
	mov	cx, SECS_PER_CLUST * 512	; bytes in cluster

.type_print_byte:
	; Check if file size remaining is zero
	cmp	word [exec_size], 0
	jne	.type_not_eof
	cmp	word [exec_size+2], 0
	je	.type_eof_pop
.type_not_eof:
	lodsb
	call	shell_putc
	; Decrement file size
	sub	word [exec_size], 1
	sbb	word [exec_size+2], 0
	dec	cx
	jnz	.type_print_byte

	; Get next cluster
	pop	ax
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.type_read_cluster

	; Done
	jmp	cmd_loop

.type_eof_pop:
	pop	ax		; Discard saved cluster
	jmp	cmd_loop

.type_disk_err_pop:
	pop	ax		; Discard saved cluster
.type_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; DEL — delete a file
; ============================================================================
do_del:
	; SI points past "DEL" — skip spaces to get filename
	call	skip_spaces
	cmp	byte [si], 0
	jne	.del_has_name
	mov	si, msg_need_fname
	call	print_string
	jmp	cmd_loop

.del_has_name:
	; Check for wildcards in the argument
	push	si
	mov	byte [wild_active], 0
.del_scan_wild:
	mov	al, [si]
	cmp	al, 0
	je	.del_wild_checked
	cmp	al, ' '
	je	.del_wild_checked
	cmp	al, '*'
	je	.del_found_wild
	cmp	al, '?'
	je	.del_found_wild
	inc	si
	jmp	.del_scan_wild
.del_found_wild:
	mov	byte [wild_active], 1
.del_wild_checked:
	pop	si

	cmp	byte [wild_active], 0
	je	.del_no_wild

	; --- Wildcard DEL ---
	; Find last separator to split dir from pattern
	push	si
	xor	bx, bx
.del_w_find_sep:
	mov	al, [si]
	cmp	al, 0
	je	.del_w_sep_done
	cmp	al, ' '
	je	.del_w_sep_done
	cmp	al, '\'
	je	.del_w_mark
	cmp	al, ':'
	je	.del_w_mark
	inc	si
	jmp	.del_w_find_sep
.del_w_mark:
	lea	bx, [si+1]
	inc	si
	jmp	.del_w_find_sep
.del_w_sep_done:
	pop	si

	; Parse wildcard pattern from the filename portion
	cmp	bx, 0
	jne	.del_w_has_dir
	; No directory part — pattern is the whole argument, use current dir
	mov	di, wild_pattern
	call	parse_wildcard
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_cur_dir
	jc	.del_disk_err
	mov	cx, [cur_dir_entries]
	jmp	.del_wild_ready

.del_w_has_dir:
	; Parse the wildcard from the filename part
	push	si
	mov	si, bx
	mov	di, wild_pattern
	call	parse_wildcard
	pop	si
	; Temporarily terminate at separator for resolve_path
	mov	al, [bx-1]
	push	ax
	mov	byte [bx-1], 0
	call	resolve_path
	pop	ax
	mov	[bx-1], al		; Restore separator
	jc	.del_not_found
	; If exec_fname is not blank, descend into it
	cmp	byte [exec_fname], ' '
	je	.del_w_resolved
	call	read_resolved_dir
	jc	.del_disk_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.del_w_find_sub:
	mov	al, [si]
	cmp	al, 0
	je	.del_not_found
	cmp	al, 0xE5
	je	.del_w_find_next
	test	byte [si+11], 0x10
	jz	.del_w_find_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.del_w_found_sub
.del_w_find_next:
	add	si, 32
	dec	cx
	jnz	.del_w_find_sub
	jmp	.del_not_found
.del_w_found_sub:
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.del_w_is_sub
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.del_w_resolved
.del_w_is_sub:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
.del_w_resolved:
	call	read_resolved_dir
	jc	.del_disk_err
	mov	cx, [resolved_dir_entries]

.del_wild_ready:
	mov	byte [.del_count], 0

	; Load FAT (save CX — read_fat clobbers it via INT 13h)
	push	cx
	call	read_fat
	pop	cx
	jc	.del_disk_err

	; Scan all entries
	mov	si, dir_buffer
.del_search:
	mov	al, [si]
	cmp	al, 0x00
	je	.del_scan_done
	cmp	al, 0xE5
	je	.del_search_next
	; Skip directories and volume labels
	test	byte [si+11], 0x18
	jnz	.del_search_next

	; Match against wildcard pattern
	mov	di, wild_pattern
	call	match_wildcard
	jc	.del_search_next	; No match

	; Match found — free its cluster chain
	mov	ax, [si+26]
	push	si
	push	cx
	call	.del_free_chain
	pop	cx
	pop	si

	; Mark entry deleted
	mov	byte [si], 0xE5
	inc	byte [.del_count]

.del_search_next:
	add	si, 32
	dec	cx
	jnz	.del_search

.del_scan_done:
	cmp	byte [.del_count], 0
	je	.del_not_found

	; Write directory back
	call	write_resolved_dir
	jc	.del_disk_err

	; Write FAT back
	call	write_fat
	jc	.del_disk_err

	jmp	cmd_loop

.del_no_wild:
	; --- Non-wildcard DEL: use resolve_path ---
	call	resolve_path
	jc	.del_not_found
	call	read_resolved_dir
	jc	.del_disk_err
	; Parse exec_fname as exact wildcard pattern (no ? or *)
	mov	si, exec_fname
	mov	di, wild_pattern
	mov	cx, 11
	rep	movsb
	mov	byte [wild_active], 1
	mov	byte [.del_count], 0
	call	read_fat
	jc	.del_disk_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.del_search

.del_not_found:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

; Free the FAT cluster chain starting at AX
.del_free_chain:
	cmp	ax, 0x002
	jb	.del_chain_done
	cmp	ax, 0xFF8
	jae	.del_chain_done

	push	ax
	call	fat12_next_cluster
	mov	[exec_cluster], ax
	pop	ax

	; Zero this cluster's FAT entry
	mov	bx, ax
	mov	cx, ax
	shr	cx, 1
	add	bx, cx

	push	ds
	mov	cx, SHELL_SEG
	mov	ds, cx
	test	ax, 1
	jz	.del_even
	mov	ax, [fat_buffer + bx]
	and	ax, 0x000F
	mov	[fat_buffer + bx], ax
	jmp	.del_zeroed
.del_even:
	mov	ax, [fat_buffer + bx]
	and	ax, 0xF000
	mov	[fat_buffer + bx], ax
.del_zeroed:
	pop	ds

	mov	ax, [exec_cluster]
	jmp	.del_free_chain

.del_chain_done:
	ret

.del_count:	db	0

.del_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; REN — rename a file
; ============================================================================
do_ren:
	; SI points past "REN" — get old filename
	call	skip_spaces
	cmp	byte [si], 0
	jne	.ren_has_old
	mov	si, msg_ren_usage
	call	print_string
	jmp	cmd_loop
.ren_has_old:
	; Resolve old filename path
	call	resolve_path
	jc	.ren_not_found

	; Save resolved directory for the old file
	mov	ax, [resolved_dir_cluster]
	push	ax
	mov	ax, [resolved_dir_entries]
	push	ax

	; Skip spaces to get new filename
	call	skip_spaces
	cmp	byte [si], 0
	jne	.ren_has_new
	pop	ax
	pop	ax
	mov	si, msg_ren_usage
	call	print_string
	jmp	cmd_loop
.ren_has_new:
	; Parse new filename (simple name only, no path)
	mov	di, ren_new_fname
	call	parse_83_filename

	; Restore resolved directory
	pop	ax
	mov	[resolved_dir_entries], ax
	pop	ax
	mov	[resolved_dir_cluster], ax

	; Read resolved directory
	call	read_resolved_dir
	jc	.ren_disk_err

	; Check that new name doesn't already exist
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.ren_check_dup:
	mov	al, [si]
	cmp	al, 0x00
	je	.ren_dup_ok
	cmp	al, 0xE5
	je	.ren_check_next
	push	cx
	push	si
	mov	di, ren_new_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.ren_exists
.ren_check_next:
	add	si, 32
	dec	cx
	jnz	.ren_check_dup
.ren_dup_ok:

	; Search for old filename
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.ren_search:
	mov	al, [si]
	cmp	al, 0x00
	je	.ren_not_found
	cmp	al, 0xE5
	je	.ren_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.ren_found
.ren_search_next:
	add	si, 32
	dec	cx
	jnz	.ren_search

.ren_not_found:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.ren_exists:
	mov	si, msg_ren_exists
	call	print_string
	jmp	cmd_loop

.ren_found:
	; Copy new name into directory entry
	mov	di, si			; DI = directory entry
	mov	si, ren_new_fname
	mov	cx, 11
	rep	movsb

	; Write resolved directory back
	call	write_resolved_dir
	jc	.ren_disk_err

	mov	si, msg_renamed
	call	print_string
	jmp	cmd_loop

.ren_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; COPY — copy a file
; ============================================================================
do_copy:
	; SI points past "COPY" — get source filename
	call	skip_spaces
	cmp	byte [si], 0
	jne	.copy_has_src
	mov	si, msg_copy_usage
	call	print_string
	jmp	cmd_loop
.copy_has_src:
	; Resolve source path
	call	resolve_path
	jc	.copy_not_found

	; Save source directory info and filename
	push	si			; Save SI (points past source in cmd_buffer)
	mov	ax, [resolved_dir_cluster]
	mov	[copy_src_dir_cl], ax
	mov	ax, [resolved_dir_entries]
	mov	[copy_src_dir_ent], ax
	mov	al, [resolved_drive]
	mov	[copy_src_drv], al
	; Copy source 8.3 name to a safe place
	mov	si, exec_fname
	mov	di, copy_src_name
	mov	cx, 11
	rep	movsb
	pop	si			; Restore SI to cmd_buffer position

	; Get dest path
	call	skip_spaces
	cmp	byte [si], 0
	jne	.copy_has_dst
	mov	si, msg_copy_usage
	call	print_string
	jmp	cmd_loop
.copy_has_dst:
	; Resolve dest path
	call	resolve_path
	jc	.copy_disk_err
	; If dest filename is blank (just a drive/path), use source filename
	cmp	byte [exec_fname], ' '
	jne	.copy_has_dest_name
	mov	si, copy_src_name
	mov	di, exec_fname
	mov	cx, 11
	rep	movsb
.copy_has_dest_name:
	; Copy dest name to ren_new_fname
	mov	si, exec_fname
	mov	di, ren_new_fname
	mov	cx, 11
	rep	movsb

	; Read dest directory to check for duplicates
	call	read_resolved_dir
	jc	.copy_disk_err

	; Save dest directory info
	mov	ax, [resolved_dir_cluster]
	mov	[copy_dst_dir_cl], ax
	mov	ax, [resolved_dir_entries]
	mov	[copy_dst_dir_ent], ax
	mov	al, [resolved_drive]
	mov	[copy_dst_drv], al

	; Check dest doesn't exist
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.copy_check_dup:
	mov	al, [si]
	cmp	al, 0x00
	je	.copy_dup_ok
	cmp	al, 0xE5
	je	.copy_dup_next
	push	cx
	push	si
	mov	di, ren_new_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.copy_exists
.copy_dup_next:
	add	si, 32
	dec	cx
	jnz	.copy_check_dup
.copy_dup_ok:

	; Find free directory entry in dest dir (before we overwrite dir_buffer)
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.copy_find_free:
	mov	al, [si]
	cmp	al, 0x00
	je	.copy_free_found
	cmp	al, 0xE5
	je	.copy_free_found
	add	si, 32
	dec	cx
	jnz	.copy_find_free
	mov	si, msg_dir_full
	call	print_string
	jmp	cmd_loop
.copy_free_found:
	mov	ax, si
	sub	ax, dir_buffer
	mov	[copy_dest_dir], ax	; Save offset, not raw pointer

	; Re-read source directory to find source file
	mov	ax, [copy_src_dir_cl]
	mov	[resolved_dir_cluster], ax
	mov	ax, [copy_src_dir_ent]
	mov	[resolved_dir_entries], ax
	mov	al, [copy_src_drv]
	mov	[resolved_drive], al
	call	read_resolved_dir
	jc	.copy_disk_err

	; Restore source filename to exec_fname
	mov	si, copy_src_name
	mov	di, exec_fname
	mov	cx, 11
	rep	movsb

	; Find source file
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.copy_search:
	mov	al, [si]
	cmp	al, 0x00
	je	.copy_not_found
	cmp	al, 0xE5
	je	.copy_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.copy_found_src
.copy_search_next:
	add	si, 32
	dec	cx
	jnz	.copy_search

.copy_not_found:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.copy_exists:
	mov	si, msg_ren_exists
	call	print_string
	jmp	cmd_loop

.copy_found_src:
	; Save source info
	mov	ax, [si+26]
	mov	[exec_cluster], ax	; Source start cluster
	mov	ax, [si+28]
	mov	[exec_size], ax		; File size low
	mov	ax, [si+30]
	mov	[exec_size+2], ax	; File size high
	; Save file attributes
	mov	al, [si+11]
	mov	[copy_src_attr], al

	; Load FAT from dest drive (allocating clusters there)
	mov	al, [copy_dst_drv]
	mov	[resolved_drive], al
	call	read_fat
	jc	.copy_disk_err

	; Allocate clusters for dest by copying source data
	; Walk source FAT chain, for each source cluster:
	;   1. Find a free cluster in FAT
	;   2. Read source cluster data
	;   3. Write data to dest cluster
	;   4. Link dest cluster in FAT chain

	mov	ax, [exec_cluster]	; Source cluster
	mov	word [copy_prev_cl], 0	; No previous dest cluster yet
	mov	word [copy_first_cl], 0	; First dest cluster (for dir entry)

.copy_next_cluster:
	mov	[copy_src_cl], ax	; Save current source cluster

	; Find a free cluster in FAT (search from cluster 2)
	push	ax
	mov	ax, 2
.copy_find_free_cl:
	cmp	ax, 720			; Max clusters for 360K
	jae	.copy_disk_full_pop
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.copy_got_free_cl
	inc	ax
	jmp	.copy_find_free_cl
.copy_got_free_cl:
	mov	[copy_dest_cl], ax

	; Mark dest cluster as EOF in FAT
	push	ax
	mov	bx, 0xFFF		; EOF marker
	call	fat12_write_cluster
	pop	ax

	; Link previous dest cluster to this one
	cmp	word [copy_prev_cl], 0
	je	.copy_first
	push	ax
	mov	ax, [copy_prev_cl]
	mov	bx, [copy_dest_cl]
	call	fat12_write_cluster
	pop	ax
	jmp	.copy_linked
.copy_first:
	mov	ax, [copy_dest_cl]
	mov	[copy_first_cl], ax
.copy_linked:
	mov	ax, [copy_dest_cl]
	mov	[copy_prev_cl], ax

	; Read source cluster into dir_buffer
	mov	ax, [copy_src_cl]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [copy_src_drv]
	int	0x13
	pop	ax			; Discard saved source cluster from find_free
	jc	.copy_disk_err

	; Write data to dest cluster
	mov	ax, [copy_dest_cl]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [copy_dst_drv]
	int	0x13
	jc	.copy_disk_err

	; Get next source cluster
	mov	ax, [copy_src_cl]
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.copy_next_cluster

	; Write updated FAT (both copies)
	call	write_fat
	jc	.copy_disk_err

	; Switch to dest directory and re-read
	mov	ax, [copy_dst_dir_cl]
	mov	[resolved_dir_cluster], ax
	mov	ax, [copy_dst_dir_ent]
	mov	[resolved_dir_entries], ax
	mov	al, [copy_dst_drv]
	mov	[resolved_drive], al
	call	read_resolved_dir
	jc	.copy_disk_err

	; Fill in the dest directory entry (reconstruct pointer from offset)
	mov	di, dir_buffer
	add	di, [copy_dest_dir]
	mov	si, ren_new_fname
	mov	cx, 11
	rep	movsb			; Copy filename
	mov	al, [copy_src_attr]
	mov	[di], al		; Attribute (DI now at offset 11)
	; Fill timestamps
	inc	di			; DI at offset 12
	call	get_fat_timestamp
	mov	cx, 10
	xor	al, al
	rep	stosb			; Zero offsets 12-21
	mov	ax, [cur_fat_time]
	stosw				; Offset 22: time
	mov	ax, [cur_fat_date]
	stosw				; Offset 24: date
	mov	ax, [copy_first_cl]
	mov	[di], ax		; Starting cluster at offset 26
	add	di, 2
	mov	ax, [exec_size]
	mov	[di], ax		; File size low at offset 28
	add	di, 2
	mov	ax, [exec_size+2]
	mov	[di], ax		; File size high at offset 30

	; Write resolved directory back
	call	write_resolved_dir
	jc	.copy_disk_err

	; Print file copied message with size
	mov	si, msg_copy_ok1
	call	print_string
	mov	ax, [exec_size]
	mov	dx, [exec_size+2]
	call	print_decimal_32
	mov	si, msg_copy_ok2
	call	print_string
	jmp	cmd_loop

.copy_disk_full_pop:
	pop	ax			; Clean stack
	mov	si, msg_disk_full
	call	print_string
	jmp	cmd_loop

.copy_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; cluster_to_chs — Convert cluster number to CHS in CH/CL/DH
; ============================================================================
; Input:  AX = cluster number
; Output: CH = cylinder, CL = sector (1-based), DH = head
;
cluster_to_chs:
	sub	ax, 2
	mov	cx, SECS_PER_CLUST
	mul	cx
	add	ax, DATA_START_SEC
	xor	dx, dx
	mov	cx, 18
	div	cx
	push	ax			; Save cylinder
	mov	ax, dx
	xor	dx, dx
	mov	cx, 9
	div	cx
	mov	dh, al			; Head
	mov	cl, dl
	inc	cl			; Sector (1-based)
	pop	ax
	mov	ch, al			; Cylinder
	ret

; ============================================================================
; fat12_read_cluster — Read FAT12 entry for a cluster
; ============================================================================
; Input:  AX = cluster number
; Output: AX = FAT entry value
;
fat12_read_cluster:
	push	bx
	push	cx
	push	dx
	mov	dx, ax			; Save cluster number for odd/even test
	mov	bx, ax
	mov	cx, ax
	shr	cx, 1
	add	bx, cx			; BX = byte offset in FAT
	push	ds
	mov	cx, SHELL_SEG
	mov	ds, cx
	mov	ax, [fat_buffer + bx]
	pop	ds
	test	dx, 1			; Test original cluster number
	jz	.frc_even
	mov	cl, 4
	shr	ax, cl
	jmp	.frc_done
.frc_even:
	and	ax, 0x0FFF
.frc_done:
	pop	dx
	pop	cx
	pop	bx
	ret

; ============================================================================
; fat12_write_cluster — Write FAT12 entry for a cluster
; ============================================================================
; Input:  AX = cluster number, BX = value to write
;
fat12_write_cluster:
	push	cx
	push	dx
	push	di
	mov	di, ax
	mov	cx, ax
	shr	cx, 1
	add	di, cx			; DI = byte offset in FAT
	push	ds
	mov	cx, SHELL_SEG
	mov	ds, cx
	test	ax, 1
	jz	.fwc_even
	; Odd: write to high 12 bits
	mov	cl, 4
	shl	bx, cl
	mov	ax, [fat_buffer + di]
	and	ax, 0x000F
	or	ax, bx
	mov	[fat_buffer + di], ax
	jmp	.fwc_done
.fwc_even:
	; Even: write to low 12 bits
	mov	ax, [fat_buffer + di]
	and	ax, 0xF000
	or	ax, bx
	mov	[fat_buffer + di], ax
.fwc_done:
	pop	ds
	pop	di
	pop	dx
	pop	cx
	ret

; ============================================================================
; CD — change current directory
; ============================================================================
do_cd:
	call	skip_spaces
	cmp	byte [si], 0
	jne	.cd_has_arg
	; No argument — print current path
	mov	al, [cur_drive]
	add	al, 'A'
	call	shell_putc
	mov	al, ':'
	call	shell_putc
	mov	al, '\'
	call	shell_putc
	cmp	byte [cur_dir_pathlen], 0
	je	.cd_print_nl
	push	si
	mov	si, cur_dir_path
	call	print_string
	pop	si
.cd_print_nl:
	call	shell_crlf
	jmp	cmd_loop

.cd_has_arg:
	; Use resolve_path to parse the argument
	; But we need to handle the case where the entire arg is a directory
	; resolve_path returns the PARENT dir + final component name
	call	resolve_path
	jc	.cd_not_found

	; If exec_fname is blank, the path ended with \ or was just a drive
	; resolved_dir_cluster IS the target directory
	cmp	byte [exec_fname], ' '
	je	.cd_set_dir

	; exec_fname has a name — look it up as a directory
	call	read_resolved_dir
	jc	.cd_disk_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.cd_search:
	mov	al, [si]
	cmp	al, 0
	je	.cd_not_found
	cmp	al, 0xE5
	je	.cd_search_next
	test	byte [si+11], 0x10
	jz	.cd_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.cd_found
.cd_search_next:
	add	si, 32
	dec	cx
	jnz	.cd_search
	jmp	.cd_not_found

.cd_found:
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.cd_is_sub
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.cd_set_dir
.cd_is_sub:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32

.cd_set_dir:
	; If changing to a different drive, save current and load new
	mov	al, [resolved_drive]
	cmp	al, [cur_drive]
	je	.cd_same_drive
	call	save_drive_state	; Save old drive state
	mov	al, [resolved_drive]
	mov	[cur_drive], al
.cd_same_drive:
	; Set current directory to resolved
	mov	ax, [resolved_dir_cluster]
	mov	[cur_dir_cluster], ax
	mov	ax, [resolved_dir_entries]
	mov	[cur_dir_entries], ax

	; If cluster is 0, we're at root — clear path
	cmp	word [cur_dir_cluster], 0
	jne	.cd_build_path
	mov	byte [cur_dir_pathlen], 0
	mov	byte [cur_dir_path], 0
	jmp	cmd_loop

.cd_build_path:
	; Rebuild path from the original argument
	; Parse each component of the original argument and apply it
	mov	si, cmd_buffer
	call	skip_spaces
	; Skip "CD "
	add	si, 2
	call	skip_spaces

	; Strip drive letter if present
	cmp	byte [si+1], ':'
	jne	.cd_no_drv_in_path
	add	si, 2
.cd_no_drv_in_path:

	; Check for absolute path
	cmp	byte [si], '\'
	jne	.cd_process_components
	inc	si
	; Absolute path — start fresh
	mov	byte [cur_dir_pathlen], 0
	mov	byte [cur_dir_path], 0

.cd_process_components:
	; Process each path component separated by '\'
	cmp	byte [si], 0
	je	.cd_path_final
	cmp	byte [si], ' '
	je	.cd_path_final

	; Check for ".."
	cmp	byte [si], '.'
	jne	.cd_comp_name
	cmp	byte [si+1], '.'
	jne	.cd_check_single_dot
	; Verify ".." is followed by \, null, or space
	cmp	byte [si+2], '\'
	je	.cd_do_dotdot
	cmp	byte [si+2], 0
	je	.cd_do_dotdot
	cmp	byte [si+2], ' '
	je	.cd_do_dotdot
	jmp	.cd_comp_name		; Not ".." — regular name

.cd_check_single_dot:
	; "." — skip it
	cmp	byte [si+1], '\'
	je	.cd_skip_dot
	cmp	byte [si+1], 0
	je	.cd_skip_dot_end
	cmp	byte [si+1], ' '
	je	.cd_skip_dot_end
	jmp	.cd_comp_name		; Not "." alone
.cd_skip_dot:
	add	si, 2			; skip ".\\"
	jmp	.cd_process_components
.cd_skip_dot_end:
	inc	si			; skip "."
	jmp	.cd_path_final

.cd_do_dotdot:
	; Remove last component from cur_dir_path
	cmp	byte [cur_dir_pathlen], 0
	je	.cd_dotdot_at_root
	mov	di, cur_dir_path
	mov	cl, [cur_dir_pathlen]
	xor	ch, ch
	add	di, cx
	dec	di
.cd_trim:
	cmp	di, cur_dir_path
	jb	.cd_dotdot_at_root
	je	.cd_dotdot_at_root2
	cmp	byte [di], '\'
	je	.cd_trim_done
	dec	di
	jmp	.cd_trim
.cd_dotdot_at_root2:
	; Only one component left — clear it
	mov	byte [cur_dir_path], 0
	mov	byte [cur_dir_pathlen], 0
	jmp	.cd_dotdot_advance
.cd_dotdot_at_root:
	mov	byte [cur_dir_pathlen], 0
	mov	byte [cur_dir_path], 0
	jmp	.cd_dotdot_advance
.cd_trim_done:
	mov	byte [di], 0
.cd_dotdot_advance:
	; Skip ".." and optional trailing '\'
	add	si, 2
	cmp	byte [si], '\'
	jne	.cd_dotdot_recount
	inc	si
.cd_dotdot_recount:
	; Recount path length
	push	si
	mov	si, cur_dir_path
	xor	cx, cx
.cd_dotdot_cnt:
	cmp	byte [si], 0
	je	.cd_dotdot_cnt_done
	inc	cx
	inc	si
	jmp	.cd_dotdot_cnt
.cd_dotdot_cnt_done:
	mov	[cur_dir_pathlen], cl
	pop	si
	jmp	.cd_process_components

.cd_comp_name:
	; Regular directory name — append to cur_dir_path
	mov	di, cur_dir_path
	mov	cl, [cur_dir_pathlen]
	xor	ch, ch
	add	di, cx
	; Add separator if path is not empty
	cmp	cx, 0
	je	.cd_comp_copy
	mov	byte [di], '\'
	inc	di
	inc	cx
.cd_comp_copy:
	; Bounds check: cur_dir_path is 65 bytes
	cmp	cx, 63
	jae	.cd_path_final		; Overflow — stop appending
	mov	al, [si]
	cmp	al, 0
	je	.cd_comp_end
	cmp	al, ' '
	je	.cd_comp_end
	cmp	al, '\'
	je	.cd_comp_sep
	; Uppercase
	cmp	al, 'a'
	jb	.cd_comp_store
	cmp	al, 'z'
	ja	.cd_comp_store
	sub	al, 0x20
.cd_comp_store:
	mov	[di], al
	inc	si
	inc	di
	inc	cx
	jmp	.cd_comp_copy
.cd_comp_sep:
	inc	si			; skip '\'
	mov	byte [di], 0		; terminate current path
	mov	[cur_dir_pathlen], cl
	jmp	.cd_process_components
.cd_comp_end:
	mov	byte [di], 0
	mov	[cur_dir_pathlen], cl

.cd_path_final:
	; Recount for safety
	mov	si, cur_dir_path
	xor	cx, cx
.cd_recount_loop:
	lodsb
	or	al, al
	jz	.cd_recount_done
	inc	cx
	jmp	.cd_recount_loop
.cd_recount_done:
	mov	[cur_dir_pathlen], cl
	call	save_drive_state	; Persist to per-drive slot
	jmp	cmd_loop

.cd_not_found:
	mov	si, msg_invalid_dir
	call	print_string
	jmp	cmd_loop

.cd_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; MKDIR — create a new subdirectory
; ============================================================================
do_mkdir:
	call	skip_spaces
	cmp	byte [si], 0
	jne	.mkdir_has_name
	mov	si, msg_need_fname
	call	print_string
	jmp	cmd_loop
.mkdir_has_name:
	call	resolve_path
	jc	.mkdir_disk_err

	; Read resolved directory
	call	read_resolved_dir
	jc	.mkdir_disk_err

	; Check name doesn't exist
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.mkdir_check_dup:
	mov	al, [si]
	cmp	al, 0
	je	.mkdir_dup_ok
	cmp	al, 0xE5
	je	.mkdir_dup_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.mkdir_exists
.mkdir_dup_next:
	add	si, 32
	dec	cx
	jnz	.mkdir_check_dup
.mkdir_dup_ok:

	; Find free directory entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.mkdir_find_free:
	mov	al, [si]
	cmp	al, 0
	je	.mkdir_free_found
	cmp	al, 0xE5
	je	.mkdir_free_found
	add	si, 32
	dec	cx
	jnz	.mkdir_find_free
	mov	si, msg_dir_full
	call	print_string
	jmp	cmd_loop
.mkdir_free_found:
	mov	ax, si
	sub	ax, dir_buffer
	mov	[copy_dest_dir], ax	; Save offset, not raw pointer

	; Load FAT
	call	read_fat
	jc	.mkdir_disk_err

	; Find a free cluster
	mov	ax, 2
.mkdir_find_cl:
	cmp	ax, 720
	jae	.mkdir_full
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.mkdir_got_cl
	inc	ax
	jmp	.mkdir_find_cl
.mkdir_got_cl:
	mov	[copy_dest_cl], ax	; Save allocated cluster

	; Mark cluster as EOF
	mov	bx, 0xFFF
	call	fat12_write_cluster

	; Write FAT back
	call	write_fat
	jc	.mkdir_disk_err

	; Get current timestamp for the new directory entries
	call	get_fat_timestamp

	; Initialize the new directory cluster with "." and ".." entries
	; Clear dir_buffer first (reuse as temp for the new directory data)
	mov	di, dir_buffer
	mov	cx, SECS_PER_CLUST * 512
	xor	al, al
	rep	stosb

	; "." entry — points to itself
	mov	di, dir_buffer
	mov	byte [di+0], '.'
	mov	cx, 10
	mov	al, ' '
	push	di
	add	di, 1
	rep	stosb
	pop	di
	mov	byte [di+11], 0x10	; Directory attribute
	mov	ax, [cur_fat_time]
	mov	[di+22], ax
	mov	ax, [cur_fat_date]
	mov	[di+24], ax
	mov	ax, [copy_dest_cl]
	mov	[di+26], ax		; Starting cluster = self

	; ".." entry — points to parent
	add	di, 32
	mov	byte [di+0], '.'
	mov	byte [di+1], '.'
	mov	cx, 9
	mov	al, ' '
	push	di
	add	di, 2
	rep	stosb
	pop	di
	mov	byte [di+11], 0x10	; Directory attribute
	mov	ax, [cur_fat_time]
	mov	[di+22], ax
	mov	ax, [cur_fat_date]
	mov	[di+24], ax
	mov	ax, [resolved_dir_cluster]
	mov	[di+26], ax		; Starting cluster = parent

	; Write the new directory data to disk
	mov	ax, [copy_dest_cl]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	jc	.mkdir_disk_err

	; Now re-read the resolved directory to add the entry
	call	read_resolved_dir
	jc	.mkdir_disk_err

	; Write the directory entry (reconstruct pointer from offset)
	mov	di, dir_buffer
	add	di, [copy_dest_dir]
	mov	si, exec_fname
	mov	cx, 11
	rep	movsb
	mov	byte [di], 0x10		; Directory attribute
	inc	di			; DI now at offset 12
	mov	cx, 10
	xor	al, al
	rep	stosb			; Zero offsets 12-21
	mov	ax, [cur_fat_time]
	stosw				; Offset 22: write time
	mov	ax, [cur_fat_date]
	stosw				; Offset 24: write date
	mov	ax, [copy_dest_cl]
	stosw				; Offset 26: starting cluster
	xor	ax, ax
	stosw				; Offset 28: size low = 0
	stosw				; Offset 30: size high = 0

	; Write resolved directory back
	call	write_resolved_dir
	jc	.mkdir_disk_err

	jmp	cmd_loop

.mkdir_exists:
	mov	si, msg_mkdir_exists
	call	print_string
	jmp	cmd_loop

.mkdir_full:
	mov	si, msg_disk_full
	call	print_string
	jmp	cmd_loop

.mkdir_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; RMDIR — remove an empty directory
; ============================================================================
do_rmdir:
	call	skip_spaces
	cmp	byte [si], 0
	jne	.rmdir_has_name
	mov	si, msg_need_fname
	call	print_string
	jmp	cmd_loop
.rmdir_has_name:
	call	resolve_path
	jc	.rmdir_not_found

	; Read the parent directory (where the dir entry lives)
	call	read_resolved_dir
	jc	.rmdir_disk_err

	; Find the directory entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.rmdir_search:
	mov	al, [si]
	cmp	al, 0
	je	.rmdir_not_found
	cmp	al, 0xE5
	je	.rmdir_search_next
	test	byte [si+11], 0x10	; Directory?
	jz	.rmdir_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.rmdir_found
.rmdir_search_next:
	add	si, 32
	dec	cx
	jnz	.rmdir_search

.rmdir_not_found:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.rmdir_found:
	; Save the entry offset and cluster
	mov	ax, si
	sub	ax, dir_buffer
	mov	[copy_dest_dir], ax	; Save offset, not raw pointer
	mov	ax, [si+26]
	mov	[copy_dest_cl], ax	; Cluster of the directory to remove

	; Don't allow removing "." or ".."
	cmp	byte [si], '.'
	jne	.rmdir_not_dotentry
	cmp	byte [si+1], ' '
	je	.rmdir_invalid
	cmp	byte [si+1], '.'
	jne	.rmdir_not_dotentry
	cmp	byte [si+2], ' '
	je	.rmdir_invalid
.rmdir_not_dotentry:

	; Check the directory is empty — read its cluster
	push	word [resolved_dir_cluster]
	push	word [resolved_dir_entries]
	mov	ax, [copy_dest_cl]
	mov	[resolved_dir_cluster], ax
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
	call	read_resolved_dir
	jc	.rmdir_disk_err_pop

	; Check entries — only "." and ".." should exist
	mov	si, dir_buffer
	mov	cx, SECS_PER_CLUST * 512 / 32
.rmdir_check_empty:
	mov	al, [si]
	cmp	al, 0			; End of directory
	je	.rmdir_is_empty
	cmp	al, 0xE5		; Deleted
	je	.rmdir_check_next
	; Check for exact "." or ".." entries
	cmp	al, '.'
	jne	.rmdir_not_dot
	cmp	byte [si+1], ' '	; "." followed by spaces
	je	.rmdir_check_next
	cmp	byte [si+1], '.'	; ".." ?
	jne	.rmdir_not_dot
	cmp	byte [si+2], ' '	; ".." followed by spaces
	je	.rmdir_check_next
.rmdir_not_dot:
	; Found a real entry — not empty
	pop	ax
	pop	ax
	mov	si, msg_rmdir_not_empty
	call	print_string
	jmp	cmd_loop
.rmdir_check_next:
	add	si, 32
	dec	cx
	jnz	.rmdir_check_empty

.rmdir_is_empty:
	; Restore parent directory context
	pop	ax
	mov	[resolved_dir_entries], ax
	pop	ax
	mov	[resolved_dir_cluster], ax

	; Free the directory's cluster in FAT
	call	read_fat
	jc	.rmdir_disk_err
	mov	ax, [copy_dest_cl]
	mov	bx, 0x000		; Free cluster
	call	fat12_write_cluster
	call	write_fat
	jc	.rmdir_disk_err

	; Re-read parent directory and mark entry as deleted
	call	read_resolved_dir
	jc	.rmdir_disk_err
	mov	si, dir_buffer
	add	si, [copy_dest_dir]	; Reconstruct pointer from offset
	mov	byte [si], 0xE5		; Mark as deleted
	call	write_resolved_dir
	jc	.rmdir_disk_err

	mov	si, msg_rmdir_ok
	call	print_string
	jmp	cmd_loop

.rmdir_invalid:
	mov	si, msg_not_found
	call	print_string
	jmp	cmd_loop

.rmdir_disk_err_pop:
	pop	ax
	pop	ax
.rmdir_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; SET — view or set environment variables
; ============================================================================
do_set:
	call	skip_spaces
	cmp	byte [si], 0
	jne	.set_has_arg

	; No argument — display all environment variables
	push	es
	push	si
	mov	es, [env_seg]
	xor	si, si
.set_show_loop:
	cmp	byte [es:si], 0		; Double null = end of env
	je	.set_show_done
.set_show_str:
	mov	al, [es:si]
	or	al, al
	jz	.set_show_next
	call	shell_putc
	inc	si
	jmp	.set_show_str
.set_show_next:
	inc	si			; Skip null terminator
	; Print newline
	call	shell_crlf
	jmp	.set_show_loop
.set_show_done:
	pop	si
	pop	es
	jmp	cmd_loop

.set_has_arg:
	; Check if there's an '=' sign
	push	si
	mov	di, si
.set_find_eq:
	mov	al, [di]
	cmp	al, 0
	je	.set_no_eq
	cmp	al, '='
	je	.set_has_eq
	inc	di
	jmp	.set_find_eq

.set_no_eq:
	; No '=' — display variables that start with the given prefix
	pop	si
	push	es
	push	si
	mov	es, [env_seg]
	xor	di, di
.set_prefix_loop:
	cmp	byte [es:di], 0
	je	.set_prefix_done
	; Compare prefix
	push	si
	push	di
.set_prefix_cmp:
	mov	al, [si]
	cmp	al, 0
	je	.set_prefix_match	; End of prefix = match
	cmp	al, ' '
	je	.set_prefix_match
	; Uppercase the input char
	cmp	al, 'a'
	jb	.set_prefix_noupper
	cmp	al, 'z'
	ja	.set_prefix_noupper
	sub	al, 0x20
.set_prefix_noupper:
	cmp	al, [es:di]
	jne	.set_prefix_skip
	inc	si
	inc	di
	jmp	.set_prefix_cmp
.set_prefix_match:
	pop	di
	pop	si
	; Print this env string
	push	di
.set_prefix_print:
	mov	al, [es:di]
	or	al, al
	jz	.set_prefix_printed
	call	shell_putc
	inc	di
	jmp	.set_prefix_print
.set_prefix_printed:
	pop	di
	call	shell_crlf
	jmp	.set_prefix_advance
.set_prefix_skip:
	pop	di
	pop	si
.set_prefix_advance:
	; Advance to next string
	cmp	byte [es:di], 0
	je	.set_prefix_next
	inc	di
	jmp	.set_prefix_advance
.set_prefix_next:
	inc	di
	jmp	.set_prefix_loop
.set_prefix_done:
	pop	si
	pop	es
	jmp	cmd_loop

.set_has_eq:
	; DI points to '='
	pop	si			; SI = start of argument
	; Save argument pointer
	mov	[.set_arg], si
	; Calculate name length
	mov	cx, di
	sub	cx, si			; CX = name length (not including '=')
	mov	[.set_namelen], cx

	; Set up ES for env block
	push	es
	mov	es, [env_seg]

	; Search for and remove existing variable with this name
	xor	di, di
.set_find_old:
	cmp	byte [es:di], 0
	je	.set_old_done
	; Compare name
	mov	si, [.set_arg]
	mov	cx, [.set_namelen]
	mov	bx, di			; Save entry start
.set_cmp_name:
	cmp	cx, 0
	je	.set_cmp_eq
	mov	al, [si]
	cmp	al, 'a'
	jb	.set_cmp_noupper
	cmp	al, 'z'
	ja	.set_cmp_noupper
	sub	al, 0x20
.set_cmp_noupper:
	cmp	al, [es:di]
	jne	.set_cmp_fail
	inc	si
	inc	di
	dec	cx
	jmp	.set_cmp_name
.set_cmp_eq:
	cmp	byte [es:di], '='
	jne	.set_cmp_fail
	; Found — remove by shifting rest of env down
	mov	di, bx			; DI = start of this entry
	mov	bx, di
.set_skip_old:
	cmp	byte [es:bx], 0
	je	.set_skipped_old
	inc	bx
	jmp	.set_skip_old
.set_skipped_old:
	inc	bx			; BX = start of next entry
.set_shift:
	mov	al, [es:bx]
	mov	[es:di], al
	cmp	al, 0
	jne	.set_shift_next
	cmp	byte [es:bx+1], 0
	je	.set_shift_done
.set_shift_next:
	inc	bx
	inc	di
	jmp	.set_shift
.set_shift_done:
	mov	byte [es:di+1], 0
	jmp	.set_old_done		; Don't advance, re-check at same pos
.set_cmp_fail:
	mov	di, bx			; Restore to entry start
.set_advance_old:
	cmp	byte [es:di], 0
	je	.set_advance_next
	inc	di
	jmp	.set_advance_old
.set_advance_next:
	inc	di
	jmp	.set_find_old
.set_old_done:

	; Check if value is empty (SET VAR= means delete only)
	mov	si, [.set_arg]
	mov	cx, [.set_namelen]
	add	si, cx			; SI past name
	inc	si			; Skip '='
	cmp	byte [si], 0
	je	.set_done
	cmp	byte [si], ' '
	je	.set_done

	; Find end of env block
	xor	bx, bx
.set_find_end2:
	cmp	byte [es:bx], 0
	je	.set_at_end2
.set_skip2:
	cmp	byte [es:bx], 0
	je	.set_skip2_null
	inc	bx
	jmp	.set_skip2
.set_skip2_null:
	inc	bx
	jmp	.set_find_end2
.set_at_end2:
	; BX = position to write new entry
	; Copy VAR=VALUE, uppercasing the name part
	mov	si, [.set_arg]
	mov	byte [.set_in_name], 1
.set_copy_new:
	mov	al, [si]
	cmp	al, 0
	je	.set_copy_done
	cmp	al, ' '
	je	.set_copy_done
	cmp	al, '='
	jne	.set_copy_not_eq
	mov	byte [.set_in_name], 0
.set_copy_not_eq:
	cmp	byte [.set_in_name], 0
	je	.set_copy_store
	cmp	al, 'a'
	jb	.set_copy_store
	cmp	al, 'z'
	ja	.set_copy_store
	sub	al, 0x20
.set_copy_store:
	mov	[es:bx], al
	inc	si
	inc	bx
	jmp	.set_copy_new
.set_copy_done:
	mov	byte [es:bx], 0
	inc	bx
	mov	byte [es:bx], 0
.set_done:
	pop	es
	jmp	cmd_loop

.set_arg:	dw	0
.set_namelen:	dw	0
.set_in_name:	db	0

; ============================================================================
; PROMPT command — set prompt format string
; ============================================================================
do_prompt:
	call	skip_spaces
	; Remove existing PROMPT= from environment
	push	es
	mov	es, [env_seg]
	xor	di, di
.prompt_find_old:
	cmp	byte [es:di], 0
	je	.prompt_old_done
	cmp	byte [es:di], 'P'
	jne	.prompt_skip_old
	cmp	byte [es:di+1], 'R'
	jne	.prompt_skip_old
	cmp	byte [es:di+2], 'O'
	jne	.prompt_skip_old
	cmp	byte [es:di+3], 'M'
	jne	.prompt_skip_old
	cmp	byte [es:di+4], 'P'
	jne	.prompt_skip_old
	cmp	byte [es:di+5], 'T'
	jne	.prompt_skip_old
	cmp	byte [es:di+6], '='
	jne	.prompt_skip_old
	; Found — remove by shifting rest down
	mov	bx, di
.prompt_skip_val:
	cmp	byte [es:bx], 0
	je	.prompt_skipped
	inc	bx
	jmp	.prompt_skip_val
.prompt_skipped:
	inc	bx			; BX = start of next entry
.prompt_shift:
	mov	al, [es:bx]
	mov	[es:di], al
	cmp	al, 0
	jne	.prompt_shift_next
	cmp	byte [es:bx+1], 0
	je	.prompt_shift_end
.prompt_shift_next:
	inc	bx
	inc	di
	jmp	.prompt_shift
.prompt_shift_end:
	mov	byte [es:di+1], 0
	jmp	.prompt_find_old	; Re-scan in case of duplicates
.prompt_skip_old:
	cmp	byte [es:di], 0
	je	.prompt_skip_old_next
	inc	di
	jmp	.prompt_skip_old
.prompt_skip_old_next:
	inc	di
	jmp	.prompt_find_old
.prompt_old_done:
	; Find the actual end of env (don't trust DI from the scan)
	xor	di, di
.prompt_find_end:
	cmp	byte [es:di], 0
	je	.prompt_at_end
.prompt_find_end_str:
	cmp	byte [es:di], 0
	je	.prompt_find_end_next
	inc	di
	jmp	.prompt_find_end_str
.prompt_find_end_next:
	inc	di
	jmp	.prompt_find_end
.prompt_at_end:
	; DI = position of final null
	; Now append PROMPT=<value>
	; Get value from command line (SI points past "PROMPT ")
	cmp	byte [si], 0
	jne	.prompt_has_arg
	; No argument — use default $P$G
	mov	si, .prompt_default
.prompt_has_arg:
	; Write "PROMPT="
	mov	byte [es:di], 'P'
	mov	byte [es:di+1], 'R'
	mov	byte [es:di+2], 'O'
	mov	byte [es:di+3], 'M'
	mov	byte [es:di+4], 'P'
	mov	byte [es:di+5], 'T'
	mov	byte [es:di+6], '='
	add	di, 7
	; Copy value (including spaces, until null)
.prompt_copy_val:
	lodsb
	mov	[es:di], al
	inc	di
	or	al, al
	jnz	.prompt_copy_val
	; Double null terminates env
	mov	byte [es:di], 0
	pop	es
	jmp	cmd_loop

.prompt_default: db	'$P$G', 0

; ============================================================================
; PATH command — display or set executable search path
; ============================================================================
do_path:
	call	skip_spaces
	cmp	byte [si], 0
	jne	.path_set
	; No argument — display current PATH
	push	es
	mov	es, [env_seg]
	xor	si, si
.path_find:
	cmp	byte [es:si], 0
	je	.path_none
	mov	al, [es:si]
	and	al, 0xDF
	cmp	al, 'P'
	jne	.path_skip
	mov	al, [es:si+1]
	and	al, 0xDF
	cmp	al, 'A'
	jne	.path_skip
	mov	al, [es:si+2]
	and	al, 0xDF
	cmp	al, 'T'
	jne	.path_skip
	mov	al, [es:si+3]
	and	al, 0xDF
	cmp	al, 'H'
	jne	.path_skip
	cmp	byte [es:si+4], '='
	jne	.path_skip
	; Found — print it
	add	si, 5
	push	si
	mov	si, .path_msg
	call	print_string
	pop	si
.path_print:
	mov	al, [es:si]
	or	al, al
	jz	.path_print_done
	call	shell_putc
	inc	si
	jmp	.path_print
.path_print_done:
	call	shell_crlf
	pop	es
	jmp	cmd_loop
.path_skip:
	cmp	byte [es:si], 0
	je	.path_skip_next
	inc	si
	jmp	.path_skip
.path_skip_next:
	inc	si
	jmp	.path_find
.path_none:
	pop	es
	mov	si, .path_no_msg
	call	print_string
	call	shell_crlf
	jmp	cmd_loop
.path_set:
	; Set PATH — reuse PROMPT's env manipulation approach
	; Build "PATH=<value>" and insert into env
	push	es
	mov	es, [env_seg]
	; Remove existing PATH=
	xor	di, di
.path_find_old:
	cmp	byte [es:di], 0
	je	.path_old_done
	mov	al, [es:di]
	and	al, 0xDF
	cmp	al, 'P'
	jne	.path_skip_old
	mov	al, [es:di+1]
	and	al, 0xDF
	cmp	al, 'A'
	jne	.path_skip_old
	mov	al, [es:di+2]
	and	al, 0xDF
	cmp	al, 'T'
	jne	.path_skip_old
	mov	al, [es:di+3]
	and	al, 0xDF
	cmp	al, 'H'
	jne	.path_skip_old
	cmp	byte [es:di+4], '='
	jne	.path_skip_old
	; Found — remove by shifting
	mov	bx, di
.path_skip_val:
	cmp	byte [es:bx], 0
	je	.path_skipped
	inc	bx
	jmp	.path_skip_val
.path_skipped:
	inc	bx
.path_shift:
	mov	al, [es:bx]
	mov	[es:di], al
	cmp	al, 0
	jne	.path_shift_next
	cmp	byte [es:bx+1], 0
	je	.path_shift_end
.path_shift_next:
	inc	bx
	inc	di
	jmp	.path_shift
.path_shift_end:
	mov	byte [es:di+1], 0
	jmp	.path_find_old
.path_skip_old:
	cmp	byte [es:di], 0
	je	.path_skip_old_next
	inc	di
	jmp	.path_skip_old
.path_skip_old_next:
	inc	di
	jmp	.path_find_old
.path_old_done:
	; Find end of env
	xor	di, di
.path_find_end:
	cmp	byte [es:di], 0
	je	.path_at_end
.path_find_end_str:
	cmp	byte [es:di], 0
	je	.path_find_end_next
	inc	di
	jmp	.path_find_end_str
.path_find_end_next:
	inc	di
	jmp	.path_find_end
.path_at_end:
	; Write PATH=<value>
	mov	byte [es:di], 'P'
	mov	byte [es:di+1], 'A'
	mov	byte [es:di+2], 'T'
	mov	byte [es:di+3], 'H'
	mov	byte [es:di+4], '='
	add	di, 5
	; Uppercase the path value
.path_copy_val:
	lodsb
	cmp	al, 'a'
	jb	.path_no_upper
	cmp	al, 'z'
	ja	.path_no_upper
	sub	al, 0x20
.path_no_upper:
	mov	[es:di], al
	inc	di
	or	al, al
	jnz	.path_copy_val
	mov	byte [es:di], 0
	pop	es
	jmp	cmd_loop

.path_msg:	db	'PATH=', 0
.path_no_msg:	db	'No Path', 0

; ============================================================================
; DATE command — display current date
; ============================================================================
do_date:
	; Print "Current date is "
	mov	si, .date_msg
	call	print_string
	mov	ah, 0x2A
	int	0x21
	; CX=year, DH=month, DL=day, AL=day of week
	push	ax
	; Print day of week
	xor	ah, ah
	mov	bx, ax
	shl	bx, 1
	shl	bx, 1			; BX = AL * 4
	add	bx, .dow_table
	push	cx
	push	dx
	mov	cx, 3
.date_dow:
	mov	al, [bx]
	call	shell_putc
	inc	bx
	dec	cx
	jnz	.date_dow
	mov	al, ' '
	call	shell_putc
	pop	dx
	pop	cx
	pop	ax
	; Print MM-DD-YYYY
	mov	al, dh			; Month
	call	.print_2dig
	mov	al, '-'
	call	shell_putc
	mov	al, dl			; Day
	call	.print_2dig
	mov	al, '-'
	call	shell_putc
	mov	ax, cx			; Year
	call	.print_year
	; Newline
	call	shell_crlf
	jmp	cmd_loop

.print_2dig:
	; Print AL as 2-digit decimal
	push	ax
	xor	ah, ah
	push	bx
	mov	bl, 10
	div	bl			; AL=tens, AH=ones
	push	ax
	add	al, '0'
	call	shell_putc
	pop	ax
	mov	al, ah
	add	al, '0'
	call	shell_putc
	pop	bx
	pop	ax
	ret

.print_year:
	; Print AX as 4-digit year
	push	bx
	push	cx
	push	dx
	xor	dx, dx
	mov	bx, 1000
	div	bx
	push	dx
	add	al, '0'
	call	shell_putc
	pop	ax
	xor	dx, dx
	mov	bx, 100
	div	bx
	push	dx
	add	al, '0'
	call	shell_putc
	pop	ax
	xor	dx, dx
	mov	bx, 10
	div	bx
	add	al, '0'
	call	shell_putc
	mov	al, dl
	add	al, '0'
	call	shell_putc
	pop	dx
	pop	cx
	pop	bx
	ret

.date_msg:	db	'Current date is ', 0

.dow_table:
	db	'Sun '
	db	'Mon '
	db	'Tue '
	db	'Wed '
	db	'Thu '
	db	'Fri '
	db	'Sat '

; ============================================================================
; TIME command — display current time
; ============================================================================
do_time:
	; Print "Current time is "
	mov	si, .time_msg
	call	print_string
	mov	ah, 0x2C
	int	0x21
	; CH=hour, CL=minute, DH=second, DL=hundredths
	mov	al, ch			; Hour
	call	do_date.print_2dig
	mov	al, ':'
	call	shell_putc
	mov	al, cl			; Minute
	call	do_date.print_2dig
	mov	al, ':'
	call	shell_putc
	mov	al, dh			; Second
	call	do_date.print_2dig
	mov	al, '.'
	call	shell_putc
	mov	al, dl			; Hundredths
	call	do_date.print_2dig
	; Newline
	call	shell_crlf
	jmp	cmd_loop

.time_msg:	db	'Current time is ', 0

; ============================================================================
; save_drive_state — Save cur_dir_* to the current drive's slot
; ============================================================================
save_drive_state:
	push	si
	push	di
	push	cx
	cmp	byte [cur_drive], 0
	jne	.sds_b
	; Save to drive A
	mov	ax, [cur_dir_cluster]
	mov	[drv_a_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[drv_a_entries], ax
	mov	al, [cur_dir_pathlen]
	mov	[drv_a_pathlen], al
	mov	si, cur_dir_path
	mov	di, drv_a_path
	mov	cx, 65
	rep	movsb
	jmp	.sds_done
.sds_b:
	mov	ax, [cur_dir_cluster]
	mov	[drv_b_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[drv_b_entries], ax
	mov	al, [cur_dir_pathlen]
	mov	[drv_b_pathlen], al
	mov	si, cur_dir_path
	mov	di, drv_b_path
	mov	cx, 65
	rep	movsb
.sds_done:
	pop	cx
	pop	di
	pop	si
	ret

; ============================================================================
; load_drive_state — Load cur_dir_* from drive A's slot (al=0) or B's (al=1)
; ============================================================================
; Input: AL = drive number (0=A, 1=B)
;
load_drive_state:
	push	si
	push	di
	push	cx
	cmp	al, 0
	jne	.lds_b
	mov	ax, [drv_a_cluster]
	mov	[cur_dir_cluster], ax
	mov	ax, [drv_a_entries]
	mov	[cur_dir_entries], ax
	mov	al, [drv_a_pathlen]
	mov	[cur_dir_pathlen], al
	mov	si, drv_a_path
	mov	di, cur_dir_path
	mov	cx, 65
	rep	movsb
	jmp	.lds_done
.lds_b:
	mov	ax, [drv_b_cluster]
	mov	[cur_dir_cluster], ax
	mov	ax, [drv_b_entries]
	mov	[cur_dir_entries], ax
	mov	al, [drv_b_pathlen]
	mov	[cur_dir_pathlen], al
	mov	si, drv_b_path
	mov	di, cur_dir_path
	mov	cx, 65
	rep	movsb
.lds_done:
	pop	cx
	pop	di
	pop	si
	ret

; ============================================================================
; read_cur_dir — Read current directory into dir_buffer
; ============================================================================
; Output: carry set on error
;
read_cur_dir:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	cmp	word [cur_dir_cluster], 0
	jne	.rcd_subdir
	mov	ah, 0x02
	mov	al, ROOT_DIR_SECS
	mov	ch, 0
	mov	cl, ROOT_DIR_SEC + 1
	mov	dh, 0
	mov	dl, [cur_drive]
	int	0x13
	ret
.rcd_subdir:
	mov	ax, [cur_dir_cluster]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [cur_drive]
	int	0x13
	ret

; ============================================================================
; write_cur_dir — Write dir_buffer back to current directory
; ============================================================================
; Output: carry set on error
;
write_cur_dir:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	cmp	word [cur_dir_cluster], 0
	jne	.wcd_subdir
	mov	ah, 0x03
	mov	al, ROOT_DIR_SECS
	mov	ch, 0
	mov	cl, ROOT_DIR_SEC + 1
	mov	dh, 0
	mov	dl, [cur_drive]
	int	0x13
	ret
.wcd_subdir:
	mov	ax, [cur_dir_cluster]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [cur_drive]
	int	0x13
	ret

; ============================================================================
; read_fat — Read FAT into fat_buffer
; ============================================================================
read_fat:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, fat_buffer
	mov	ah, 0x02
	mov	al, 2
	mov	ch, 0
	mov	cl, FAT_SEC + 1
	mov	dh, 0
	mov	dl, [resolved_drive]
	int	0x13
	ret

; ============================================================================
; write_fat — Write fat_buffer to both FAT copies
; ============================================================================
write_fat:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, fat_buffer
	mov	ah, 0x03
	mov	al, 2
	mov	ch, 0
	mov	cl, FAT_SEC + 1
	mov	dh, 0
	mov	dl, [resolved_drive]
	int	0x13
	jc	.wf_done
	mov	bx, fat_buffer
	mov	ah, 0x03
	mov	al, 2
	mov	ch, 0
	mov	cl, FAT_SEC + 3
	mov	dh, 0
	mov	dl, [resolved_drive]
	int	0x13
.wf_done:
	ret

; ============================================================================
; resolve_path — Resolve a path string to directory cluster + filename
; ============================================================================
; Input:  SI = pointer to path string (e.g., "SUBDIR\FILE.TXT" or "\DIR\FILE")
; Output: resolved_dir_cluster = cluster of directory containing the file
;         resolved_dir_entries = max entries in that directory
;         exec_fname = parsed 8.3 filename of the final component
;         carry set = error (directory not found)
;         carry clear = success
;
; Handles: absolute paths (\DIR\FILE), relative paths (DIR\FILE),
;          plain filenames (FILE.TXT), ".." components
;
resolve_path:
	push	bx
	push	cx
	push	dx

	; Default to current drive
	mov	al, [cur_drive]
	mov	[resolved_drive], al

	; Check for drive letter prefix (e.g., "A:" or "a:")
	cmp	byte [si+1], ':'
	jne	.rp_no_drive
	mov	al, [si]
	; Uppercase
	cmp	al, 'a'
	jb	.rp_drive_upper
	cmp	al, 'z'
	ja	.rp_no_drive
	sub	al, 0x20
.rp_drive_upper:
	cmp	al, 'A'
	jb	.rp_no_drive
	cmp	al, 'B'
	ja	.rp_no_drive
	sub	al, 'A'			; 0=A, 1=B
	mov	[resolved_drive], al
	add	si, 2			; Skip "X:"
	; Drive letter with \ = absolute from root
	; Drive letter without \ = relative to that drive's current dir
	cmp	byte [si], '\'
	je	.rp_absolute
	; No backslash — relative to specified drive's current dir
	cmp	byte [resolved_drive], 0
	jne	.rp_drv_b_rel
	mov	ax, [drv_a_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [drv_a_entries]
	mov	[resolved_dir_entries], ax
	jmp	.rp_parse_component
.rp_drv_b_rel:
	mov	ax, [drv_b_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [drv_b_entries]
	mov	[resolved_dir_entries], ax
	jmp	.rp_parse_component
.rp_no_drive:

	; Start from current directory or root
	cmp	byte [si], '\'
	jne	.rp_relative
.rp_absolute:
	; Absolute path — start from root
	mov	word [resolved_dir_cluster], 0
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	inc	si			; Skip leading '\'
	jmp	.rp_parse_component
.rp_relative:
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax

.rp_parse_component:
	; Check if we're at the end of the string
	cmp	byte [si], 0
	je	.rp_no_file		; Path ends with no filename
	cmp	byte [si], ' '
	je	.rp_no_file

	; Parse next component into exec_fname
	mov	di, exec_fname
	call	parse_83_filename

	; Check if there's more path after this component
	; SI was advanced by parse_83_filename
	; Check if we stopped at a '\'
	cmp	byte [si], '\'
	je	.rp_descend
	; No more '\' — this is the final filename
	; resolved_dir_cluster and exec_fname are set
	clc
	jmp	.rp_done

.rp_descend:
	inc	si			; Skip the '\'

	; Handle "." (current dir) — skip it, no directory lookup needed
	cmp	byte [exec_fname], '.'
	jne	.rp_not_dot
	cmp	byte [exec_fname+1], ' '
	je	.rp_parse_component	; "." — stay in current dir, continue parsing

	; Handle ".." — look up ".." entry (works in subdirs)
	; For root dir (cluster 0), ".." stays at root
	cmp	byte [exec_fname+1], '.'
	jne	.rp_not_dot
	cmp	byte [exec_fname+2], ' '
	jne	.rp_not_dot
	cmp	word [resolved_dir_cluster], 0
	jne	.rp_not_dot		; Not root — normal lookup will find ".."
	; At root, ".." stays at root
	jmp	.rp_parse_component

.rp_not_dot:
	; Look up this component in the current resolved directory
	; Save SI (rest of path)
	push	si

	; Read the resolved directory
	call	read_resolved_dir
	jc	.rp_err_pop

	; Search for the component with directory attribute
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.rp_search:
	mov	al, [si]
	cmp	al, 0
	je	.rp_not_found_pop
	cmp	al, 0xE5
	je	.rp_search_next
	test	byte [si+11], 0x10	; Directory?
	jz	.rp_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.rp_found_dir
.rp_search_next:
	add	si, 32
	dec	cx
	jnz	.rp_search

.rp_not_found_pop:
	pop	si
	stc
	jmp	.rp_done

.rp_err_pop:
	pop	si
	stc
	jmp	.rp_done

.rp_found_dir:
	; Update resolved directory to this subdirectory
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.rp_is_sub
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.rp_restored
.rp_is_sub:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
.rp_restored:
	pop	si			; Restore rest of path
	jmp	.rp_parse_component

.rp_no_file:
	; Path was just a directory path with no filename
	; Put empty filename in exec_fname
	mov	di, exec_fname
	mov	cx, 11
	mov	al, ' '
	rep	stosb
	clc

.rp_done:
	pop	dx
	pop	cx
	pop	bx
	ret

; ============================================================================
; read_resolved_dir — Read directory at resolved_dir_cluster into dir_buffer
; ============================================================================
read_resolved_dir:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	cmp	word [resolved_dir_cluster], 0
	jne	.rrd_subdir
	; Read root directory one sector at a time (avoid head boundary crossing)
	push	cx
	push	dx
	mov	cx, ROOT_DIR_SECS
	mov	ax, ROOT_DIR_SEC	; LBA of first root dir sector
.rrd_root_loop:
	push	cx
	push	ax
	; Convert LBA to CHS
	xor	dx, dx
	push	bx
	mov	bx, 9			; Sectors per track
	div	bx			; AX = track*heads + head, DX = sector
	pop	bx
	mov	cl, dl
	inc	cl			; CHS sector (1-based)
	xor	dx, dx
	push	bx
	mov	bx, 2			; Heads
	div	bx
	pop	bx
	mov	ch, al			; Cylinder
	mov	dh, dl			; Head
	mov	dl, [resolved_drive]
	mov	ah, 0x02
	mov	al, 1			; 1 sector
	int	0x13
	pop	ax
	pop	cx
	jc	.rrd_root_err
	add	bx, 512			; Advance buffer
	inc	ax			; Next LBA
	dec	cx
	jnz	.rrd_root_loop
	pop	dx
	pop	cx
	clc
	ret
.rrd_root_err:
	pop	dx
	pop	cx
	stc
	ret
.rrd_subdir:
	mov	ax, [resolved_dir_cluster]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	ret

; ============================================================================
; write_resolved_dir — Write dir_buffer to resolved_dir_cluster
; ============================================================================
write_resolved_dir:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	cmp	word [resolved_dir_cluster], 0
	jne	.wrd_subdir
	; Write root directory one sector at a time
	push	cx
	push	dx
	mov	cx, ROOT_DIR_SECS
	mov	ax, ROOT_DIR_SEC
.wrd_root_loop:
	push	cx
	push	ax
	xor	dx, dx
	push	bx
	mov	bx, 9
	div	bx
	pop	bx
	mov	cl, dl
	inc	cl
	xor	dx, dx
	push	bx
	mov	bx, 2
	div	bx
	pop	bx
	mov	ch, al
	mov	dh, dl
	mov	dl, [resolved_drive]
	mov	ah, 0x03
	mov	al, 1
	int	0x13
	pop	ax
	pop	cx
	jc	.wrd_root_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.wrd_root_loop
	pop	dx
	pop	cx
	clc
	ret
.wrd_root_err:
	pop	dx
	pop	cx
	stc
	ret
.wrd_subdir:
	mov	ax, [resolved_dir_cluster]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	ret

; ============================================================================
; run_batch — Load and execute a batch file
; ============================================================================
; Input: SI = pointer to filename string (e.g., "AUTOEXEC.BAT")
; Silently does nothing if file not found.
; Sets batch_active=1 and batch_ptr, then returns to cmd_loop which
; will read lines from the batch buffer instead of the keyboard.
;
run_batch:
	; Resolve the filename
	call	resolve_path
	jc	.rb_not_found

	; Read resolved directory
	call	read_resolved_dir
	jc	.rb_not_found

	; Search for the file
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.rb_search:
	mov	al, [si]
	cmp	al, 0
	je	.rb_not_found
	cmp	al, 0xE5
	je	.rb_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.rb_found
.rb_search_next:
	add	si, 32
	dec	cx
	jnz	.rb_search

.rb_not_found:
	ret

.rb_found:
	; Get cluster and size
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	mov	ax, [si+28]
	mov	[exec_size], ax
	mov	ax, [si+30]
	mov	[exec_size+2], ax

	; Load FAT
	call	read_fat
	jc	.rb_not_found

	; Load file data into batch_buffer
	mov	bx, batch_buffer
	mov	ax, [exec_cluster]

.rb_load_cluster:
	push	ax
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	pop	ax
	jc	.rb_not_found

	add	bx, SECS_PER_CLUST * 512
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.rb_load_cluster

	; Set up batch execution
	mov	ax, batch_buffer
	add	ax, [exec_size]
	mov	[batch_end], ax
	mov	word [batch_ptr], batch_buffer
	mov	byte [batch_active], 1
	mov	byte [batch_echo], 1	; Echo on by default
	ret

; ============================================================================
; batch_next_line — Get next line from batch buffer into cmd_buffer
; ============================================================================
; Called from cmd_loop when batch_active is set.
; Copies one line, handles @, REM, PAUSE, then falls through to command dispatch.
;
batch_next_line:
	mov	si, [batch_ptr]
	mov	di, cmd_buffer
	mov	cx, MAX_CMD_LEN

.bnl_copy:
	cmp	si, [batch_end]
	jae	.bnl_eof
	lodsb
	cmp	al, 0x0A		; LF = end of line
	je	.bnl_line_done
	cmp	al, 0x0D		; CR = skip
	je	.bnl_copy
	cmp	al, 0x1A		; Ctrl-Z = EOF
	je	.bnl_eof
	stosb
	dec	cx
	jnz	.bnl_copy

.bnl_line_done:
	mov	byte [di], 0
	mov	[batch_ptr], si

	; Skip empty lines
	mov	si, cmd_buffer
	call	skip_spaces
	cmp	byte [si], 0
	je	cmd_loop		; Empty line — get next

	; Check for @ prefix — suppress echo for this line
	mov	byte [batch_buffer - 1], 0  ; temp: this_line_silent flag (reuse byte before buffer)
	cmp	byte [si], '@'
	jne	.bnl_check_echo_state
	mov	byte [batch_buffer - 1], 1  ; This line is silent
	; Strip @ from buffer
	inc	si
	mov	di, cmd_buffer
.bnl_shift:
	lodsb
	stosb
	or	al, al
	jnz	.bnl_shift

.bnl_check_echo_state:
	; Check for ECHO OFF / ECHO ON
	mov	si, cmd_buffer
	call	skip_spaces
	push	si
	mov	di, cmd_echo
	call	str_compare_cmd
	jne	.bnl_not_echo_cmd
	; It's an ECHO command — check for OFF/ON
	call	skip_spaces
	push	si
	mov	di, str_off
	call	str_compare_cmd
	je	.bnl_echo_off
	pop	si
	push	si
	mov	di, str_on
	call	str_compare_cmd
	je	.bnl_echo_on
	pop	si
	pop	si			; Discard saved SI from echo check
	jmp	.bnl_do_echo_line	; Regular ECHO with text

.bnl_echo_off:
	pop	si
	pop	si
	mov	byte [batch_echo], 0
	jmp	cmd_loop
.bnl_echo_on:
	pop	si
	pop	si
	mov	byte [batch_echo], 1
	jmp	cmd_loop

.bnl_not_echo_cmd:
	pop	si

.bnl_do_echo_line:
	; Echo the line if echo is on AND line is not @-prefixed
	cmp	byte [batch_buffer - 1], 1
	je	.bnl_skip_echo		; @ prefix — don't echo
	cmp	byte [batch_echo], 0
	je	.bnl_skip_echo		; Echo off — don't echo
	; Echo the line
	push	si
	mov	si, cmd_buffer
	call	print_string
	call	shell_crlf
	pop	si
.bnl_skip_echo:

	; Check for REM (comment) — skip
	mov	si, cmd_buffer
	call	skip_spaces
	push	si
	mov	di, cmd_rem
	call	str_compare_cmd
	je	.bnl_skip_rem

	; Check for PAUSE
	pop	si
	push	si
	mov	di, cmd_pause
	call	str_compare_cmd
	je	.bnl_do_pause

	pop	si
	; Fall through to normal command dispatch
	jmp	cmd_dispatch

.bnl_skip_rem:
	pop	si
	jmp	cmd_loop

.bnl_do_pause:
	pop	si
	mov	si, msg_pause
	call	print_string
	mov	ah, 0x00
	int	0x16
	call	shell_crlf
	jmp	cmd_loop

.bnl_eof:
	mov	byte [batch_active], 0
	jmp	cmd_loop

; ============================================================================
; print_2digit — Print AX as 2-digit number with leading zero
; ============================================================================
print_2digit:
	push	ax
	push	bx
	xor	ah, ah
	mov	bl, 10
	div	bl			; AL = tens, AH = ones
	push	ax
	add	al, '0'
	call	shell_putc
	pop	ax
	mov	al, ah
	add	al, '0'
	call	shell_putc
	pop	bx
	pop	ax
	ret

; ============================================================================
; print_2digit_space — Print AX as 2-digit with leading space (not zero)
; ============================================================================
print_2digit_space:
	push	ax
	push	bx
	xor	ah, ah
	mov	bl, 10
	div	bl			; AL = tens, AH = ones
	push	ax
	cmp	al, 0
	jne	.p2ds_tens
	mov	al, ' '			; Space instead of '0'
	jmp	.p2ds_print_tens
.p2ds_tens:
	add	al, '0'
.p2ds_print_tens:
	call	shell_putc
	pop	ax
	mov	al, ah
	add	al, '0'
	call	shell_putc
	pop	bx
	pop	ax
	ret

; ============================================================================
; print_size_padded — Print DX:AX as right-aligned number in 10 chars
; ============================================================================
print_size_padded:
	push	ax
	push	bx
	push	cx
	push	dx

	; Count digits first
	push	ax
	push	dx
	mov	cx, 0
	mov	bx, 10
.psp_count:
	push	ax
	mov	ax, dx
	xor	dx, dx
	div	bx
	mov	word [.psp_tmp], ax
	pop	ax
	div	bx
	push	dx
	mov	dx, [.psp_tmp]
	inc	cx
	or	ax, ax
	jnz	.psp_count
	or	dx, dx
	jnz	.psp_count

	; Print leading spaces (10 - digit_count)
	mov	bx, cx		; Save digit count
	mov	ax, 10
	sub	ax, cx
	mov	cx, ax
	jcxz	.psp_no_pad
.psp_pad:
	mov	al, ' '
	call	shell_putc
	dec	cx
	jnz	.psp_pad
.psp_no_pad:
	; Discard counted digits from stack
	mov	cx, bx
.psp_discard:
	pop	ax
	dec	cx
	jnz	.psp_discard
	pop	dx
	pop	ax

	; Now print the actual number
	call	print_decimal_32

	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret
.psp_tmp	dw	0

; ============================================================================
; print_rpad_dec — Print DX:AX right-aligned in CX character width
; ============================================================================
print_rpad_dec:
	push	ax
	push	bx
	push	cx
	push	dx
	; Use print_size_padded logic but with variable width
	; For simplicity, just print spaces then the number
	; Count digits
	push	ax
	push	dx
	push	cx			; Save width
	mov	cx, 0
	mov	bx, 10
.prpd_count:
	push	ax
	mov	ax, dx
	xor	dx, dx
	div	bx
	mov	[.prpd_tmp], ax
	pop	ax
	div	bx
	push	dx
	mov	dx, [.prpd_tmp]
	inc	cx
	or	ax, ax
	jnz	.prpd_count
	or	dx, dx
	jnz	.prpd_count
	mov	bx, cx			; BX = digit count
	; Discard digits from stack
.prpd_pop:
	pop	ax
	dec	cx
	jnz	.prpd_pop
	pop	cx			; Restore width
	pop	dx
	pop	ax
	; Print (width - digits) spaces
	sub	cx, bx
	jle	.prpd_no_pad
.prpd_pad:
	push	ax
	mov	al, ' '
	call	shell_putc
	pop	ax
	dec	cx
	jnz	.prpd_pad
.prpd_no_pad:
	call	print_decimal_32
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret
.prpd_tmp	dw	0

cmd_rem		db	'REM', 0
cmd_pause	db	'PAUSE', 0
str_off		db	'OFF', 0
str_on		db	'ON', 0

; ============================================================================
; parse_83_filename — Parse filename at DS:SI into 8.3 format at ES:DI
; ============================================================================
; Input:  SI = pointer to filename string (null/space terminated)
;         DI = pointer to 11-byte output buffer
; Output: DI buffer filled with 8.3 name (space padded)
;         SI advanced past the filename
;
parse_83_filename:
	cld
	push	ax
	push	cx
	push	di
	; Fill with spaces
	push	di
	mov	cx, 11
	mov	al, ' '
	rep	stosb
	pop	di

	; Special case: "." and ".." are stored as-is, not as name.ext
	cmp	byte [si], '.'
	jne	.p83_normal
	cmp	byte [si+1], '.'
	je	.p83_dotdot
	; Check if "." is alone (followed by \, space, or null)
	cmp	byte [si+1], '\'
	je	.p83_single_dot
	cmp	byte [si+1], ' '
	je	.p83_single_dot
	cmp	byte [si+1], 0
	je	.p83_single_dot
	jmp	.p83_normal		; "." followed by something else = has extension
.p83_single_dot:
	mov	byte [di], '.'
	inc	si
	jmp	.p83_done
.p83_dotdot:
	; Check ".." is alone
	cmp	byte [si+2], '\'
	je	.p83_is_dotdot
	cmp	byte [si+2], ' '
	je	.p83_is_dotdot
	cmp	byte [si+2], 0
	je	.p83_is_dotdot
	jmp	.p83_normal
.p83_is_dotdot:
	mov	byte [di], '.'
	mov	byte [di+1], '.'
	add	si, 2
	jmp	.p83_done

.p83_normal:
	; Copy name part (up to 8 chars)
	mov	cx, 8
.p83_name:
	mov	al, [si]
	cmp	al, 0
	je	.p83_done
	cmp	al, ' '
	je	.p83_done
	cmp	al, '\'
	je	.p83_done
	cmp	al, '.'
	je	.p83_dot
	cmp	al, 'a'
	jb	.p83_no_upper
	cmp	al, 'z'
	ja	.p83_no_upper
	sub	al, 0x20
.p83_no_upper:
	mov	[di], al
	inc	si
	inc	di
	dec	cx
	jnz	.p83_name
	; Skip to dot or end
.p83_skip:
	mov	al, [si]
	cmp	al, 0
	je	.p83_done
	cmp	al, ' '
	je	.p83_done
	cmp	al, '\'
	je	.p83_done
	cmp	al, '.'
	je	.p83_dot
	inc	si
	jmp	.p83_skip
.p83_dot:
	inc	si
	pop	di
	push	di
	add	di, 8			; Extension at offset 8
	mov	cx, 3
.p83_ext:
	mov	al, [si]
	cmp	al, 0
	je	.p83_done
	cmp	al, ' '
	je	.p83_done
	cmp	al, '\'
	je	.p83_done
	cmp	al, 'a'
	jb	.p83_no_upper2
	cmp	al, 'z'
	ja	.p83_no_upper2
	sub	al, 0x20
.p83_no_upper2:
	mov	[di], al
	inc	si
	inc	di
	dec	cx
	jnz	.p83_ext
.p83_done:
	pop	di
	pop	cx
	pop	ax
	ret

; ============================================================================
; parse_wildcard — parse filename with * and ? into 11-byte pattern
; Input: SI = user string, DI = 11-byte buffer
; '*' fills remaining name/ext positions with '?'
; Output: SI advanced past parsed name
;         Sets wild_active=1 if any wildcards found, else 0
; ============================================================================
parse_wildcard:
	push	ax
	push	cx
	push	di
	mov	byte [wild_active], 0
	; Fill with spaces
	push	di
	mov	cx, 11
	mov	al, ' '
	rep	stosb
	pop	di

	; Name part (up to 8 chars)
	mov	cx, 8
.pw_name:
	mov	al, [si]
	cmp	al, 0
	je	.pw_done
	cmp	al, ' '
	je	.pw_done
	cmp	al, '\'
	je	.pw_done
	cmp	al, '.'
	je	.pw_dot
	cmp	al, '*'
	je	.pw_star_name
	cmp	al, '?'
	jne	.pw_name_char
	mov	byte [wild_active], 1
.pw_name_char:
	cmp	al, 'a'
	jb	.pw_name_store
	cmp	al, 'z'
	ja	.pw_name_store
	sub	al, 0x20
.pw_name_store:
	mov	[di], al
	inc	si
	inc	di
	dec	cx
	jnz	.pw_name
	jmp	.pw_skip_to_dot

.pw_star_name:
	mov	byte [wild_active], 1
	; Fill rest of name with '?'
	mov	al, '?'
.pw_fill_name:
	cmp	cx, 0
	je	.pw_star_name_done
	mov	[di], al
	inc	di
	dec	cx
	jmp	.pw_fill_name
.pw_star_name_done:
	inc	si		; skip the '*'
	; Skip to dot or end
.pw_skip_to_dot:
	mov	al, [si]
	cmp	al, '.'
	je	.pw_dot
	cmp	al, 0
	je	.pw_star_ext	; No extension after * means match all extensions
	cmp	al, ' '
	je	.pw_star_ext
	cmp	al, '\'
	je	.pw_star_ext
	inc	si
	jmp	.pw_skip_to_dot

.pw_dot:
	inc	si		; skip '.'
	pop	di
	push	di
	add	di, 8		; extension part
	mov	cx, 3
.pw_ext:
	mov	al, [si]
	cmp	al, 0
	je	.pw_done
	cmp	al, ' '
	je	.pw_done
	cmp	al, '\'
	je	.pw_done
	cmp	al, '*'
	je	.pw_star_ext
	cmp	al, '?'
	jne	.pw_ext_char
	mov	byte [wild_active], 1
.pw_ext_char:
	cmp	al, 'a'
	jb	.pw_ext_store
	cmp	al, 'z'
	ja	.pw_ext_store
	sub	al, 0x20
.pw_ext_store:
	mov	[di], al
	inc	si
	inc	di
	dec	cx
	jnz	.pw_ext
	jmp	.pw_done

.pw_star_ext:
	mov	byte [wild_active], 1
	; Fill rest of extension with '?'
	pop	di
	push	di
	add	di, 8
	mov	cx, 3
	mov	al, '?'
.pw_fill_ext:
	cmp	cx, 0
	je	.pw_done
	mov	[di], al
	inc	di
	dec	cx
	jmp	.pw_fill_ext

.pw_done:
	pop	di
	pop	cx
	pop	ax
	ret

; ============================================================================
; match_wildcard — check if dir entry matches wildcard pattern
; Input: SI = pointer to dir entry (11-byte name), DI = 11-byte pattern
; Output: ZF=1 if match, ZF=0 if no match
; Preserves all registers
; ============================================================================
match_wildcard:
	push	cx
	push	si
	push	di
	mov	cx, 11
.mw_next:
	mov	al, [di]
	cmp	al, '?'
	je	.mw_skip		; '?' matches anything
	cmp	al, [si]
	jne	.mw_no_match
.mw_skip:
	inc	si
	inc	di
	dec	cx
	jnz	.mw_next
	; All 11 matched
	pop	di
	pop	si
	pop	cx
	clc			; CF=0 = match
	ret
.mw_no_match:
	pop	di
	pop	si
	pop	cx
	stc			; CF=1 = no match
	ret

; ============================================================================
; EXEC — load and execute .COM file
; ============================================================================
do_exec:
	; SI points to the command (filename)
	; Resolve path
	call	resolve_path
	jc	.exec_not_found
	; Save SI — it now points to the command tail (arguments)
	mov	[exec_cmdtail_ptr], si

	; If no extension was given, try .COM → .EXE → .BAT
	mov	byte [exec_try_ext], 0
	cmp	byte [exec_fname+8], ' '
	jne	.has_ext
	mov	byte [exec_fname+8], 'C'
	mov	byte [exec_fname+9], 'O'
	mov	byte [exec_fname+10], 'M'
	mov	byte [exec_try_ext], 1	; 1=try EXE next, 2=try BAT next
	jmp	.has_ext
.exec_retry_ext:
	cmp	byte [exec_try_ext], 1
	jne	.exec_retry_bat
	mov	byte [exec_fname+8], 'E'
	mov	byte [exec_fname+9], 'X'
	mov	byte [exec_fname+10], 'E'
	mov	byte [exec_try_ext], 2
	jmp	.has_ext
.exec_retry_bat:
	mov	byte [exec_fname+8], 'B'
	mov	byte [exec_fname+9], 'A'
	mov	byte [exec_fname+10], 'T'
	mov	byte [exec_try_ext], 0
.has_ext:

	; Read resolved directory
	call	read_resolved_dir
	jc	.exec_disk_err

	; Search for file
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]

.search_entry:
	mov	al, [si]
	cmp	al, 0x00
	je	.exec_not_found
	cmp	al, 0xE5
	je	.search_next

	; Compare 11-byte filename
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.exec_found

.search_next:
	add	si, 32
	dec	cx
	jnz	.search_entry

.exec_not_found:
	; Try next extension: .COM → .EXE → .BAT
	cmp	byte [exec_try_ext], 0
	je	.exec_really_not_found
	jmp	.exec_retry_ext

.exec_really_not_found:
	; Before giving up, try searching PATH directories
	cmp	byte [path_searched], 1
	je	.exec_really_done	; Already searched PATH, give up
	mov	byte [path_searched], 1
	call	search_path
	jnc	.exec_path_hit
.exec_really_done:
	mov	byte [path_searched], 0
	mov	si, msg_bad_cmd
	call	print_string
	jmp	cmd_loop
.exec_path_hit:
	; search_path set resolved_dir_cluster/entries and exec_fname.
	; Set up for the file search just like do_exec does.
	mov	byte [path_searched], 0
	; Find command tail in path_cmd_save (skip past command name)
	push	si
	mov	si, path_cmd_save
.exec_path_skip_name:
	lodsb
	cmp	al, ' '
	je	.exec_path_found_tail
	cmp	al, 0
	je	.exec_path_no_tail
	jmp	.exec_path_skip_name
.exec_path_no_tail:
	; No arguments — use empty tail
	mov	word [exec_cmdtail_ptr], exec_empty_tail
	jmp	.exec_path_tail_done
.exec_path_found_tail:
	; SI points past the space — back up to include the space
	dec	si
	mov	[exec_cmdtail_ptr], si
.exec_path_tail_done:
	pop	si
	; Extension retry: try .COM if no ext
	mov	byte [exec_try_ext], 0
	cmp	byte [exec_fname+8], ' '
	jne	.exec_path_has_ext
	mov	byte [exec_fname+8], 'C'
	mov	byte [exec_fname+9], 'O'
	mov	byte [exec_fname+10], 'M'
	mov	byte [exec_try_ext], 1
.exec_path_has_ext:
	; Read the target directory and search
	call	read_resolved_dir
	jc	.exec_really_done
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.search_entry

.exec_found:
	; Check if this is a .BAT file — run through batch processor
	cmp	byte [exec_fname+8], 'B'
	jne	.exec_not_bat
	cmp	byte [exec_fname+9], 'A'
	jne	.exec_not_bat
	cmp	byte [exec_fname+10], 'T'
	jne	.exec_not_bat
	; It's a .BAT — rebuild name and call run_batch
	mov	di, cmd_buffer
	mov	si, exec_fname
	mov	cx, 8
.exec_bat_copy:
	lodsb
	cmp	al, ' '
	je	.exec_bat_ext
	mov	[di], al
	inc	di
	dec	cx
	jnz	.exec_bat_copy
.exec_bat_ext:
	mov	byte [di], '.'
	inc	di
	mov	byte [di], 'B'
	inc	di
	mov	byte [di], 'A'
	inc	di
	mov	byte [di], 'T'
	inc	di
	mov	byte [di], 0
	mov	si, cmd_buffer
	call	run_batch
	jmp	cmd_loop

.exec_not_bat:
	; SI points to the matching directory entry
	; Get starting cluster (offset 26)
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	; Get file size (offset 28)
	mov	ax, [si+28]
	mov	[exec_size], ax
	mov	ax, [si+30]
	mov	[exec_size+2], ax

	; Load FAT
	call	read_fat
	jc	.exec_disk_err

	; Allocate memory for the program
	; Size in paragraphs = (file_size + 256 (PSP) + 15) / 16 + some stack
	; For .COM: allocate all available memory (like DOS)
	; For .EXE: allocate based on header
	mov	bx, 0xFFFF		; Request maximum
	call	alloc_mem_core		; Will fail but BX = largest block
	; Now allocate that largest block
	call	alloc_mem_core
	jc	.exec_no_mem
	; Save parent's exec_seg before overwriting
	push	bx
	mov	bx, [exec_seg]
	mov	[exec_parent_psp], bx
	pop	bx
	mov	[exec_seg], ax		; Save allocated segment

	; Create PSP at allocated segment
	mov	es, ax

	; Clear PSP area first
	push	ax
	push	cx
	push	di
	xor	di, di
	xor	ax, ax
	mov	cx, 128			; 256 bytes / 2
	rep	stosw
	pop	di
	pop	cx
	pop	ax

	; PSP:00 — INT 20h instruction
	mov	byte [es:0x00], 0xCD	; INT
	mov	byte [es:0x01], 0x20	; 20h

	; PSP:02 — Memory top segment (exec_seg + block size from MCB)
	push	es
	mov	ax, [exec_seg]
	dec	ax
	mov	es, ax			; ES = MCB
	mov	ax, [es:0x03]		; Block size in paragraphs
	add	ax, [exec_seg]
	inc	ax			; Top = exec_seg + size + 1
	pop	es
	mov	[es:0x02], ax

	; PSP:05 — FAR CALL to DOS (CP/M compat: CALL 5 → INT 21h)
	mov	byte [es:0x05], 0xCD	; INT
	mov	byte [es:0x06], 0x21	; 21h
	mov	byte [es:0x07], 0xCB	; RETF

	; PSP:0A — Save parent's INT 22h (terminate handler)
	push	ds
	xor	ax, ax
	mov	ds, ax
	mov	ax, [ds:0x88]		; INT 22h offset
	mov	[es:0x0A], ax
	mov	ax, [ds:0x8A]		; INT 22h segment
	mov	[es:0x0C], ax
	; PSP:0E — Save parent's INT 23h (Ctrl-C handler)
	mov	ax, [ds:0x8C]		; INT 23h offset
	mov	[es:0x0E], ax
	mov	ax, [ds:0x8E]		; INT 23h segment
	mov	[es:0x10], ax
	; PSP:12 — Save parent's INT 24h (critical error handler)
	mov	ax, [ds:0x90]		; INT 24h offset
	mov	[es:0x12], ax
	mov	ax, [ds:0x92]		; INT 24h segment
	mov	[es:0x14], ax
	pop	ds

	; PSP:16 — Parent PSP segment (shell's own segment)
	mov	word [es:0x16], SHELL_SEG

	; PSP:18 — Job File Table (20 bytes)
	; Fill all 20 with 0xFF (closed), then set standard handles
	push	di
	push	cx
	; Inherit parent's JFT (copies redirected handles)
	mov	di, 0x18
	push	ds
	mov	ds, [cs:exec_parent_psp]
	mov	si, 0x18
	mov	cx, MAX_HANDLES
	rep	movsb
	pop	ds
	; Increment refcounts for inherited FILE handles (5+)
	; Device handles 0-4 are permanent and don't need refcounting
	push	bx
	mov	bx, 5
.inherit_refcount:
	cmp	bx, MAX_HANDLES
	jae	.inherit_done
	mov	al, [es:0x18 + bx]
	cmp	al, 0xFF
	je	.inherit_next
	xor	ah, ah
	push	bx
	mov	bx, ax
	inc	byte [cs:sft_refcount + bx]
	pop	bx
.inherit_next:
	inc	bx
	jmp	.inherit_refcount
.inherit_done:
	pop	bx
	pop	cx
	pop	di

	; PSP:2C — Environment segment
	mov	ax, [env_seg]
	mov	[es:0x2C], ax

	; PSP:32 — Max file handles (must match MAX_HANDLES)
	mov	word [es:0x32], MAX_HANDLES
	; PSP:34 — Pointer to handle table (default: PSP:18)
	mov	word [es:0x34], 0x18
	mov	ax, [exec_seg]
	mov	word [es:0x36], ax

	; PSP:50 — INT 21h / RETF (for CP/M-style CALL PSP:50)
	mov	byte [es:0x50], 0xCD	; INT
	mov	byte [es:0x51], 0x21	; 21h
	mov	byte [es:0x52], 0xCB	; RETF

	; PSP:5C — FCB #1 (parse first arg from command tail)
	; DS:SI = source string (shell seg), ES:DI = FCB in PSP
	push	si
	push	di
	mov	si, [exec_cmdtail_ptr]
	; DS is already SHELL_SEG, ES is already PSP seg
	mov	di, 0x5C
	mov	ax, 0x2900
	int	0x21
	; PSP:6C — FCB #2 (parse second arg)
	; SI was advanced past first arg by AH=29
	mov	di, 0x6C
	mov	ax, 0x2900
	int	0x21
	pop	di
	pop	si

	; Command tail at PSP:80h
	; Format: [length byte] [space] [arguments...] [0x0D]
	push	si
	push	di
	mov	si, [exec_cmdtail_ptr]
	mov	di, 0x81		; Start after length byte
	xor	cx, cx			; Count characters
	; Copy command tail
.exec_copy_tail:
	lodsb
	cmp	al, 0
	je	.exec_tail_done
	cmp	cx, 126			; Max 126 chars
	jae	.exec_tail_done
	stosb
	inc	cx
	jmp	.exec_copy_tail
.exec_tail_done:
	mov	byte [es:di], 0x0D	; Terminate with CR
	mov	byte [es:0x80], cl	; Length byte
	pop	di
	pop	si

	; Set default DTA to PSP:0080
	mov	ax, [exec_seg]
	mov	[dta_seg], ax
	mov	word [dta_off], 0x0080

	; Load file to allocated_seg:0100
	; Advance ES by cluster size each iteration to avoid 64K crossing
	mov	bx, 0x0100
	mov	ax, [exec_cluster]

.load_cluster:
	push	ax
	; Read cluster one sector at a time to avoid track boundary issues
	sub	ax, 2
	mov	cx, SECS_PER_CLUST
	push	cx
	mul	cx
	add	ax, DATA_START_SEC	; AX = first linear sector
	mov	[cs:exec_cur_sec], ax
	pop	cx			; CX = sectors to read
.load_sector:
	push	cx
	; Convert linear sector to CHS
	mov	ax, [cs:exec_cur_sec]
	xor	dx, dx
	push	bx
	mov	bx, 18			; SPT * heads
	div	bx
	mov	ch, al			; Cylinder
	mov	ax, dx
	xor	dx, dx
	mov	bx, 9			; SPT
	div	bx
	mov	dh, al			; Head
	mov	cl, dl
	inc	cl			; Sector (1-based)
	pop	bx
	; Read 1 sector
	push	es
	mov	ah, 0x02
	mov	al, 1
	mov	dl, [resolved_drive]
	int	0x13
	pop	es
	jc	.exec_disk_err_free_pop
	; Advance buffer by 512 bytes (32 paragraphs)
	mov	ax, es
	add	ax, 512 / 16
	mov	es, ax
	inc	word [cs:exec_cur_sec]
	pop	cx
	dec	cx
	jnz	.load_sector

	pop	ax
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.load_cluster

	; Save all vectors before launching program (preserves TSR hooks)
	push	ds
	xor	ax, ax
	mov	ds, ax
	; BIOS vectors
	mov	ax, [ds:0x20]
	mov	[cs:saved_int08], ax
	mov	ax, [ds:0x22]
	mov	[cs:saved_int08+2], ax
	mov	ax, [ds:0x24]
	mov	[cs:saved_int09], ax
	mov	ax, [ds:0x26]
	mov	[cs:saved_int09+2], ax
	mov	ax, [ds:0x40]
	mov	[cs:saved_int10], ax
	mov	ax, [ds:0x42]
	mov	[cs:saved_int10+2], ax
	mov	ax, [ds:0x70]
	mov	[cs:saved_int1c], ax
	mov	ax, [ds:0x72]
	mov	[cs:saved_int1c+2], ax
	; DOS vectors (INT 20h-24h)
	mov	ax, [ds:0x80]
	mov	[cs:saved_int20], ax
	mov	ax, [ds:0x82]
	mov	[cs:saved_int20+2], ax
	mov	ax, [ds:0x84]
	mov	[cs:saved_int21], ax
	mov	ax, [ds:0x86]
	mov	[cs:saved_int21+2], ax
	mov	ax, [ds:0x88]
	mov	[cs:saved_int22], ax
	mov	ax, [ds:0x8A]
	mov	[cs:saved_int22+2], ax
	mov	ax, [ds:0x8C]
	mov	[cs:saved_int23], ax
	mov	ax, [ds:0x8E]
	mov	[cs:saved_int23+2], ax
	mov	ax, [ds:0x90]
	mov	[cs:saved_int24], ax
	mov	ax, [ds:0x92]
	mov	[cs:saved_int24+2], ax
	pop	ds

	; Check if .EXE by looking at first two bytes (MZ signature)
	mov	ax, [exec_seg]
	mov	es, ax
	cmp	word [es:0x100], 0x5A4D	; 'MZ'
	je	.exec_is_exe

	; === .COM execution ===
	; Set up far jump target BEFORE changing DS
	mov	word [exec_jmp_ip], 0x0100	; Reset (EXE may have changed it)
	mov	ax, [exec_seg]
	mov	[exec_jmp_cs], ax

	; Update INT 20h to use cleanup handler
	push	ax
	xor	ax, ax
	push	es
	mov	es, ax
	mov	word [es:0x80], int20_handler
	mov	word [es:0x82], SHELL_SEG
	pop	es
	pop	ax

	; Now set up program segments
	mov	ax, [exec_seg]
	mov	ds, ax
	mov	es, ax
	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti

	; Jump to program
	jmp	far [cs:exec_jmp_ip]

	; === .EXE execution ===
.exec_is_exe:
	; Read MZ header from exec_seg:0100
	mov	ax, [exec_seg]
	mov	es, ax

	; Header size in paragraphs (at file offset 0x08 → memory 0x108)
	mov	ax, [es:0x108]
	mov	[exe_hdr_size], ax

	; Code segment = exec_seg + 0x10 (PSP) + header_paras
	mov	bx, [exec_seg]
	add	bx, 0x10		; Past PSP
	add	bx, ax			; Past MZ header
	mov	[exe_load_seg], bx

	; Get initial CS:IP from header
	mov	ax, [es:0x116]		; Initial CS (relative)
	add	ax, bx			; Make absolute
	mov	[exec_jmp_cs], ax	; CS for far jump

	mov	ax, [es:0x114]		; Initial IP
	mov	[exec_jmp_ip], ax	; IP for far jump

	; Get initial SS:SP from header
	mov	ax, [es:0x10E]		; Initial SS (relative)
	add	ax, bx			; Make absolute
	mov	dx, [es:0x110]		; Initial SP

	; Apply relocations
	mov	cx, [es:0x106]		; Relocation count
	jcxz	.exec_exe_no_reloc
	mov	di, [es:0x118]		; Relocation table file offset
	add	di, 0x100		; Adjust for load at :0100

.exec_exe_reloc:
	push	cx
	mov	si, [es:di]		; Reloc offset
	mov	cx, [es:di+2]		; Reloc segment (relative)
	add	cx, [exe_load_seg]	; Make absolute
	push	es
	push	di
	mov	es, cx
	mov	di, si
	mov	cx, [es:di]		; Read current value
	add	cx, [cs:exe_load_seg]	; Add load segment
	mov	[es:di], cx		; Write back
	pop	di
	pop	es
	pop	cx
	add	di, 4
	dec	cx
	jnz	.exec_exe_reloc

.exec_exe_no_reloc:
	; Set up execution
	cli
	mov	ss, ax			; SS from header
	mov	sp, dx			; SP from header
	sti

	; DS = ES = PSP segment (standard DOS .EXE convention)
	mov	ax, [exec_seg]
	mov	ds, ax
	mov	es, ax

	; Far jump to CS:IP
	jmp	far [cs:exec_jmp_ip]

.exec_no_mem:
	mov	si, msg_no_mem
	call	print_string
	jmp	cmd_loop

.exec_disk_err_free_pop:
	pop	cx			; Clean sector loop counter
.exec_disk_err_free:
	pop	ax			; Clean stack from push in load_cluster
	; Free allocated memory
	mov	es, [exec_seg]
	mov	ah, 0x49
	int	0x21

.exec_disk_err:
	mov	si, msg_disk_err
	call	print_string
	jmp	cmd_loop

; ============================================================================
; fat12_next_cluster — Get next cluster from FAT12
; ============================================================================
; Input:  AX = current cluster
; Output: AX = next cluster (>= 0xFF8 means end)
fat12_next_cluster:
	push	bx
	push	cx
	push	dx

	mov	dx, ax			; Save cluster number for odd/even test
	mov	bx, ax
	; FAT12 entry offset = cluster * 1.5 = cluster + cluster/2
	mov	cx, ax
	shr	cx, 1
	add	bx, cx			; BX = byte offset into FAT

	; Read 16-bit value from FAT buffer
	push	ds
	mov	cx, SHELL_SEG
	mov	ds, cx
	mov	ax, [fat_buffer + bx]
	pop	ds

	; If original cluster was odd, shift right 4
	test	dx, 1			; Was original cluster odd?
	jz	.even_cluster
	mov	cl, 4
	shr	ax, cl
	jmp	.fat_done
.even_cluster:
	and	ax, 0x0FFF
.fat_done:
	pop	dx
	pop	cx
	pop	bx
	ret

; ============================================================================
; alloc_mem_core — callable memory allocator (no INT overhead)
; ============================================================================
; Input: BX = requested paragraphs
; Output: CF=0, AX = allocated segment  /  CF=1, AX=8, BX=largest available
; Clobbers: CX, DX, DI, ES
alloc_mem_core:
	mov	ax, [cs:mcb_first]
	mov	cx, bx			; CX = requested size
	mov	dx, 0			; DX = largest free found
.walk:
	mov	es, ax
	cmp	byte [es:0x00], 'M'
	je	.check
	cmp	byte [es:0x00], 'Z'
	je	.check
	jmp	.fail			; Corrupt MCB
.check:
	cmp	word [es:0x01], 0	; Free?
	jne	.next
	; Save this block's type before we might split it
	push	ax
	mov	al, [es:0x00]
	mov	[cs:.amc_type], al
	pop	ax
	; Free block — check size
	mov	bx, [es:0x03]
	cmp	bx, dx			; Track largest
	jbe	.not_larger
	mov	dx, bx
.not_larger:
	cmp	bx, cx			; Big enough?
	jb	.next
	; Allocate from this block
	mov	di, bx
	sub	di, cx
	cmp	di, 1			; Room for a new MCB?
	jbe	.take_all
	; Split: shrink this block, create new MCB after
	mov	word [es:0x03], cx	; Resize current block
	push	ax
	inc	ax
	mov	[es:0x01], ax		; Owner = allocated segment (MCB+1)
	pop	ax
	push	ax
	add	ax, cx
	inc	ax
	push	es
	mov	es, ax
	mov	bl, [cs:.amc_type]
	mov	[es:0x00], bl		; New block gets original type
	mov	word [es:0x01], 0	; Free
	sub	di, 1
	mov	[es:0x03], di		; Remaining size
	pop	es
	mov	byte [es:0x00], 'M'	; Current is no longer last
	pop	ax
	jmp	.ok
.take_all:
	push	ax
	inc	ax
	mov	[es:0x01], ax		; Owner = MCB+1
	pop	ax
	jmp	.ok_nosplit
.next:
	mov	bl, [es:0x00]
	mov	[cs:.amc_type], bl
	cmp	byte [es:0x00], 'Z'
	je	.fail
	mov	bx, [es:0x03]
	add	ax, bx
	inc	ax
	jmp	.walk
.ok:
	inc	ax			; Return segment = MCB + 1
	clc
	ret
.ok_nosplit:
	mov	ax, es
	inc	ax
	clc
	ret
.fail:
	mov	bx, dx			; Return largest available
	mov	ax, 8			; Error: insufficient memory
	stc
	ret
.amc_type	db	'M'

; ============================================================================
; INT 21h — DOS Services Handler
; ============================================================================
; Provides basic DOS-compatible services for .COM programs.
;
int21_handler:
	cmp	ah, 0x01
	je	.i21_01
	cmp	ah, 0x02
	je	.i21_02
	cmp	ah, 0x06
	je	.i21_06
	cmp	ah, 0x07
	je	.i21_07
	cmp	ah, 0x08
	je	.i21_08
	cmp	ah, 0x09
	je	.i21_09
	cmp	ah, 0x0A
	je	.i21_0a
	cmp	ah, 0x0B
	je	.i21_0b
	cmp	ah, 0x0C
	je	.i21_0c
	cmp	ah, 0x0D
	je	.i21_0d
	cmp	ah, 0x25
	je	.i21_25
	cmp	ah, 0x30
	je	.i21_30
	cmp	ah, 0x35
	je	.i21_35
	cmp	ah, 0x3C
	je	.i21_3c
	cmp	ah, 0x3D
	je	.i21_3d
	cmp	ah, 0x3E
	je	.i21_3e
	cmp	ah, 0x3F
	je	.i21_3f
	cmp	ah, 0x40
	je	.i21_40
	cmp	ah, 0x42
	je	.i21_42
	cmp	ah, 0x48
	je	.i21_48
	cmp	ah, 0x49
	je	.i21_49
	cmp	ah, 0x4A
	je	.i21_4a
	cmp	ah, 0x19
	je	.i21_19
	cmp	ah, 0x1A
	je	.i21_1a
	cmp	ah, 0x2A
	je	.i21_2a
	cmp	ah, 0x2C
	je	.i21_2c
	cmp	ah, 0x2F
	je	.i21_2f
	cmp	ah, 0x36
	je	.i21_36
	cmp	ah, 0x44
	je	.i21_44
	cmp	ah, 0x45
	je	.i21_45
	cmp	ah, 0x46
	je	.i21_46
	cmp	ah, 0x47
	je	.i21_47
	cmp	ah, 0x4B
	je	.i21_4b
	cmp	ah, 0x4C
	je	.i21_4c
	cmp	ah, 0x4D
	je	.i21_4d
	cmp	ah, 0x0E
	je	.i21_0e
	cmp	ah, 0x26
	je	.i21_26
	cmp	ah, 0x29
	je	.i21_29
	cmp	ah, 0x39
	je	.i21_39
	cmp	ah, 0x3A
	je	.i21_3a
	cmp	ah, 0x3B
	je	.i21_3b
	cmp	ah, 0x41
	je	.i21_41
	cmp	ah, 0x43
	je	.i21_43
	cmp	ah, 0x4E
	je	.i21_4e
	cmp	ah, 0x4F
	je	.i21_4f
	cmp	ah, 0x56
	je	.i21_56
	cmp	ah, 0x57
	je	.i21_57
	cmp	ah, 0x33
	je	.i21_33
	cmp	ah, 0x37
	je	.i21_37
	cmp	ah, 0x38
	je	.i21_38
	cmp	ah, 0x54
	je	.i21_54
	cmp	ah, 0x58
	je	.i21_58
	cmp	ah, 0x59
	je	.i21_59
	cmp	ah, 0x0F
	je	.i21_0f
	cmp	ah, 0x10
	je	.i21_10
	cmp	ah, 0x11
	je	.i21_11
	cmp	ah, 0x12
	je	.i21_12
	cmp	ah, 0x13
	je	.i21_13
	cmp	ah, 0x14
	je	.i21_14
	cmp	ah, 0x15
	je	.i21_15
	cmp	ah, 0x16
	je	.i21_16
	cmp	ah, 0x2B
	je	.i21_2b
	cmp	ah, 0x2D
	je	.i21_2d
	cmp	ah, 0x62
	je	.i21_62
	cmp	ah, 0x21
	je	.i21_21
	cmp	ah, 0x22
	je	.i21_22
	cmp	ah, 0x00
	je	.i21_00
	cmp	ah, 0x03
	je	.i21_03
	cmp	ah, 0x04
	je	.i21_04
	cmp	ah, 0x05
	je	.i21_05
	cmp	ah, 0x1B
	je	.i21_1b
	cmp	ah, 0x1C
	je	.i21_1c
	cmp	ah, 0x23
	je	.i21_23
	cmp	ah, 0x24
	je	.i21_24
	cmp	ah, 0x34
	je	.i21_34
	cmp	ah, 0x17
	je	.i21_17
	cmp	ah, 0x27
	je	.i21_27
	cmp	ah, 0x28
	je	.i21_28
	cmp	ah, 0x50
	je	.i21_50
	cmp	ah, 0x51
	je	.i21_51
	cmp	ah, 0x5B
	je	.i21_5b
	cmp	ah, 0x1F
	je	.i21_1f
	cmp	ah, 0x32
	je	.i21_32
	cmp	ah, 0x31
	je	.i21_31
	; Unhandled — return error (CF=1, AX=1 invalid function)
	mov	ax, 1
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=01: Read character with echo ---
.i21_01:
	call	con_read_al	; Read char from CON driver
	push	ax
	call	con_write_al	; Echo through CON driver
	pop	ax
	iret

; --- AH=02: Display character (DL) ---
.i21_02:
	; Write character DL to stdout (handle 1)
	; If handle 1 is a device, use INT 10h for speed
	; If handle 1 is a file, use AH=40h to write
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	es
	mov	es, [cs:exec_seg]
	mov	bl, [es:0x18 + 1]	; JFT[1] = SFT index for stdout
	xor	bh, bh
	push	bx
	mov	cl, 4
	shl	bx, cl
	test	byte [cs:file_handles + bx], 0x80
	pop	bx
	jnz	.i21_02_device
	; File — write via AH=40h
	mov	[cs:.i21_02_char], dl
	pop	es
	pop	si
	mov	ah, 0x40
	mov	bx, 1			; Handle 1 (stdout)
	mov	cx, 1			; 1 byte
	mov	dx, .i21_02_char
	push	ds
	push	cs
	pop	ds
	int	0x21
	pop	ds
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	iret
.i21_02_device:
	; Device — write through CON driver
	pop	es
	pop	si
	mov	al, dl
	call	con_write_al
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	iret
.i21_02_char:	db	0

; --- AH=06: Direct console I/O ---
; DL=FF: input (ZF=1 if no char, AL=char if available)
; DL<FF: output character DL
.i21_06:
	cmp	dl, 0xFF
	je	.i21_06_input
	; Output through CON driver
	push	ax
	mov	al, dl
	call	con_write_al
	pop	ax
	iret
.i21_06_input:
	call	con_check_input
	jz	.i21_06_nokey
	call	con_read_al	; Consume the key
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFBF	; Clear ZF in saved flags
	pop	bp
	iret
.i21_06_nokey:
	xor	al, al
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0040	; Set ZF in saved flags
	pop	bp
	iret

; --- AH=07: Direct char input without echo ---
.i21_07:
	call	con_read_al
	iret

; --- AH=08: Read char without echo (checks Ctrl-C) ---
.i21_08:
	call	con_read_al
	iret

; --- AH=09: Print $-terminated string at DS:DX ---
.i21_09:
	push	ax
	push	dx
	push	si
	mov	si, dx
.i21_09_loop:
	lodsb
	cmp	al, '$'
	je	.i21_09_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21		; Recurse through AH=02 (handles redirection)
	jmp	.i21_09_loop
.i21_09_done:
	pop	si
	pop	dx
	pop	ax
	iret

; --- AH=0A: Buffered input ---
; DS:DX points to buffer: [max_len] [actual_len] [data...]
.i21_0a:
	push	ax
	push	bx
	push	cx
	push	di
	mov	di, dx
	mov	cl, [di]	; Max length
	xor	ch, ch
	dec	cx		; Leave room for CR
	add	di, 2		; Point to data area
	xor	bx, bx		; Character count
.i21_0a_loop:
	call	con_read_al	; Read key from CON driver
	cmp	al, 0x0D	; Enter?
	je	.i21_0a_done
	cmp	al, 0x08	; Backspace?
	je	.i21_0a_bs
	cmp	bx, cx		; Buffer full?
	jge	.i21_0a_loop
	mov	[di+bx], al
	inc	bx
	; Echo through CON driver
	call	con_write_al
	jmp	.i21_0a_loop
.i21_0a_bs:
	cmp	bx, 0
	je	.i21_0a_loop
	dec	bx
	mov	al, 0x08
	call	con_write_al
	mov	al, ' '
	call	con_write_al
	mov	al, 0x08
	call	con_write_al
	jmp	.i21_0a_loop
.i21_0a_done:
	mov	byte [di+bx], 0x0D	; CR at end
	mov	di, dx
	mov	[di+1], bl		; Store actual length
	; Echo CR/LF
	mov	al, 0x0D
	call	con_write_al
	mov	al, 0x0A
	call	con_write_al
	pop	di
	pop	cx
	pop	bx
	pop	ax
	iret

; --- AH=0B: Check input status ---
; Returns AL=FF if char available, AL=00 if not
.i21_0b:
	call	con_check_input
	jz	.i21_0b_none
	mov	al, 0xFF
	iret
.i21_0b_none:
	xor	al, al
	iret

; --- AH=0C: Flush buffer then read ---
; AL = function to call after flush (01, 06, 07, 08, 0A)
.i21_0c:
	; Flush CON input buffer, then dispatch sub-function
	push	ax
	push	bx
	push	es
	call	con_setup_esbx
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 7	; INPUT FLUSH command
	mov	word [cs:drv_request+3], 0
	call	drv_call
	pop	es
	pop	bx
	pop	ax
	; Now dispatch the sub-function
	mov	ah, al
	int	0x21
	iret

; --- AH=25: Set interrupt vector ---
; AL = interrupt number, DS:DX = new handler
.i21_25:
	push	ax
	push	bx
	push	es
	xor	bx, bx
	mov	es, bx
	xor	bh, bh
	mov	bl, al
	shl	bx, 1
	shl	bx, 1		; BX = AL * 4
	mov	[es:bx], dx	; Offset
	mov	[es:bx+2], ds	; Segment
	pop	es
	pop	bx
	pop	ax
	iret

; --- AH=30: Get DOS version ---
; Returns AL=major, AH=minor
.i21_30:
	mov	ax, 0x0003	; DOS 3.0
	xor	bx, bx
	xor	cx, cx
	iret

; --- AH=35: Get interrupt vector ---
; AL = interrupt number → ES:BX = handler address
.i21_35:
	push	ax
	push	ds
	xor	bx, bx
	mov	ds, bx
	xor	bh, bh
	mov	bl, al
	shl	bx, 1
	shl	bx, 1		; BX = AL * 4
	mov	ax, [bx+2]	; Segment
	mov	bx, [bx]	; Offset
	mov	es, ax
	pop	ds
	pop	ax
	iret

; --- AH=3C: Create file ---
; Input: DS:DX = ASCIIZ filename, CX = attributes
; Output: AX = handle, CF=0 on success
.i21_3c:
	push	bx
	push	cx
	push	si
	push	di
	push	es

	mov	[cs:.i21_3c_attr], cx

	; Find a free handle (start at 5)
	mov	bx, 5
.i21_3c_find_handle:
	cmp	bx, MAX_HANDLES
	jae	.i21_3c_no_handle
	mov	ax, bx
	push	bx
	push	cx
	mov	cl, 4
	shl	bx, cl
	cmp	byte [cs:file_handles + bx], 0
	pop	cx
	pop	bx
	je	.i21_3c_got_handle
	inc	bx
	jmp	.i21_3c_find_handle
.i21_3c_got_handle:
	mov	[cs:.i21_3c_handle], bx

	; Copy filename from caller's DS:DX to cmd_buffer
	mov	[cs:.i21_3c_ds], ds
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, cmd_buffer
	mov	si, dx
	mov	cx, 64
.i21_3c_copy:
	lodsb
	mov	[es:di], al
	inc	di
	or	al, al
	jz	.i21_3c_copied
	dec	cx
	jnz	.i21_3c_copy
	mov	byte [es:di-1], 0
.i21_3c_copied:

	; Switch to SHELL_SEG
	mov	ds, [cs:.i21_3c_ds]	; Keep caller's DS for now
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax

	; Resolve path
	mov	si, cmd_buffer
	call	resolve_path
	jc	.i21_3c_err_pop

	; Read resolved directory
	call	read_resolved_dir
	jc	.i21_3c_err_pop

	; Check if file already exists — if so, truncate (overwrite)
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_3c_check:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3c_not_exists
	cmp	al, 0xE5
	je	.i21_3c_check_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_3c_exists
.i21_3c_check_next:
	add	si, 32
	dec	cx
	jnz	.i21_3c_check

.i21_3c_not_exists:
	; Find a free directory entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_3c_find_free:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3c_free_found
	cmp	al, 0xE5
	je	.i21_3c_free_found
	add	si, 32
	dec	cx
	jnz	.i21_3c_find_free
	jmp	.i21_3c_dir_full

.i21_3c_free_found:
	; Allocate a cluster for the file
	call	read_fat
	jc	.i21_3c_err_pop
	mov	ax, 2
.i21_3c_find_cl:
	cmp	ax, 720
	jae	.i21_3c_disk_full
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.i21_3c_got_cl
	inc	ax
	jmp	.i21_3c_find_cl
.i21_3c_got_cl:
	mov	[cs:.i21_3c_cluster], ax
	; Mark cluster as EOF
	mov	bx, 0xFFF
	call	fat12_write_cluster
	call	write_fat
	jc	.i21_3c_err_pop

	; Create directory entry
	; SI still points to the free slot
	call	get_fat_timestamp
	mov	di, si
	mov	si, exec_fname
	mov	cx, 11
	rep	movsb			; Filename
	mov	ax, [cs:.i21_3c_attr]
	mov	byte [di], al		; Attribute
	inc	di
	mov	cx, 10
	xor	al, al
	rep	stosb			; Zero offsets 12-21
	mov	ax, [cur_fat_time]
	stosw				; Offset 22: write time
	mov	ax, [cur_fat_date]
	stosw				; Offset 24: write date
	mov	ax, [cs:.i21_3c_cluster]
	mov	[di], ax		; Starting cluster
	add	di, 2
	xor	ax, ax
	mov	[di], ax		; File size = 0
	add	di, 2
	mov	[di], ax

	; Write directory back
	call	write_resolved_dir
	jc	.i21_3c_err_pop
	jmp	.i21_3c_setup_handle

.i21_3c_exists:
	; File exists — truncate to 0 (reuse its cluster)
	mov	ax, [si+26]		; Existing start cluster
	mov	[cs:.i21_3c_cluster], ax
	; Set file size to 0
	mov	word [si+28], 0
	mov	word [si+30], 0
	call	write_resolved_dir
	jc	.i21_3c_err_pop

.i21_3c_setup_handle:
	; Fill handle entry
	mov	bx, [cs:.i21_3c_handle]
	mov	ax, bx
	mov	cl, 4
	shl	ax, cl
	mov	di, ax

	mov	byte [cs:file_handles + di], 2	; Open for write
	mov	al, [cs:resolved_drive]
	mov	[cs:file_handles + di + 1], al
	mov	ax, [cs:.i21_3c_cluster]
	mov	[cs:file_handles + di + 2], ax	; Start cluster
	mov	[cs:file_handles + di + 4], ax	; Current cluster
	mov	word [cs:file_handles + di + 6], 0  ; Cluster position
	mov	word [cs:file_handles + di + 8], 0  ; File pointer
	mov	word [cs:file_handles + di + 10], 0
	mov	word [cs:file_handles + di + 12], 0 ; File size = 0
	mov	word [cs:file_handles + di + 14], 0
	; Set JFT entry, refcount, and directory location
	push	es
	mov	es, [cs:exec_seg]
	mov	bx, [cs:.i21_3c_handle]
	mov	[es:0x18 + bx], bl	; JFT[handle] = SFT index (same number)
	mov	byte [cs:sft_refcount + bx], 1
	; Save directory cluster/entries for close-time size update
	mov	ax, [resolved_dir_cluster]
	shl	bx, 1			; Word index
	mov	[cs:sft_dir_cluster + bx], ax
	mov	ax, [resolved_dir_entries]
	mov	[cs:sft_dir_entries + bx], ax
	mov	word [cs:sft_devinfo + bx], 0	; Disk file
	pop	es

	pop	ds			; Restore caller's DS
	mov	ax, [cs:.i21_3c_handle]
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_3c_no_handle:
	mov	ax, 4
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_3c_err_pop:
	pop	ds
.i21_3c_disk_full:
.i21_3c_dir_full:
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 5
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_3c_attr	dw	0
.i21_3c_handle	dw	0
.i21_3c_ds	dw	0
.i21_3c_cluster	dw	0

; --- AH=3D: Open file ---
; Input: DS:DX = ASCIIZ filename, AL = access mode (0=read, 1=write, 2=r/w)
; Output: AX = handle, CF=0 on success
.i21_3d:
	push	bx
	push	cx
	push	si
	push	di
	push	es

	mov	[cs:.i21_3d_mode], al	; Save access mode

	; Find a free handle (start at 5)
	mov	bx, 5
.i21_3d_find_handle:
	cmp	bx, MAX_HANDLES
	jae	.i21_3d_no_handle
	mov	ax, bx
	push	bx
	mov	cl, 4			; * 16 = FH_SIZE
	shl	bx, cl
	cmp	byte [cs:file_handles + bx], 0	; Closed?
	pop	bx
	je	.i21_3d_got_handle
	inc	bx
	jmp	.i21_3d_find_handle

.i21_3d_got_handle:
	mov	[cs:.i21_3d_handle], bx

	; Parse filename from DS:DX using resolve_path
	; Save DS (caller's segment)
	mov	[cs:.i21_3d_ds], ds
	push	bx

	; Set DS to SHELL_SEG for resolve_path
	mov	ax, SHELL_SEG
	mov	ds, ax

	; Copy filename from caller's DS:DX to cmd_buffer
	mov	es, ax			; ES = SHELL_SEG
	mov	di, cmd_buffer
	push	ds
	mov	ds, [cs:.i21_3d_ds]
	mov	si, dx
	mov	cx, 64
.i21_3d_copy_name:
	lodsb
	stosb
	or	al, al
	jz	.i21_3d_name_done
	dec	cx
	jnz	.i21_3d_copy_name
	mov	byte [es:di-1], 0
.i21_3d_name_done:
	pop	ds			; DS = SHELL_SEG again

	mov	si, cmd_buffer
	call	resolve_path
	jc	.i21_3d_not_found

	; Read directory
	call	read_resolved_dir
	jc	.i21_3d_not_found

	; Search for file
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_3d_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3d_not_found
	cmp	al, 0xE5
	je	.i21_3d_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_3d_found
.i21_3d_search_next:
	add	si, 32
	dec	cx
	jnz	.i21_3d_search

.i21_3d_not_found:
	pop	bx
	mov	ds, [cs:.i21_3d_ds]
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 2			; File not found
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_3d_found:
	; Fill handle entry
	pop	bx			; Handle number
	push	bx
	mov	ax, bx
	mov	cl, 4
	shl	ax, cl
	mov	di, ax			; DI = handle table offset

	; Flags
	mov	al, [cs:.i21_3d_mode]
	inc	al			; 0→1(read), 1→2(write), 2→3(r/w)
	mov	[cs:file_handles + di], al
	; Drive
	mov	al, [resolved_drive]
	mov	[cs:file_handles + di + 1], al
	; Start cluster
	mov	ax, [si+26]
	mov	[cs:file_handles + di + 2], ax
	; Current cluster = start cluster
	mov	[cs:file_handles + di + 4], ax
	; Position in cluster = 0
	mov	word [cs:file_handles + di + 6], 0
	; File pointer = 0
	mov	word [cs:file_handles + di + 8], 0
	mov	word [cs:file_handles + di + 10], 0
	; File size
	mov	ax, [si+28]
	mov	[cs:file_handles + di + 12], ax
	mov	ax, [si+30]
	mov	[cs:file_handles + di + 14], ax

	; Set JFT entry, refcount, and directory location
	pop	bx			; Handle number
	push	bx
	push	es
	mov	es, [cs:exec_seg]
	mov	[es:0x18 + bx], bl	; JFT[handle] = SFT index
	mov	byte [cs:sft_refcount + bx], 1
	; Save directory cluster/entries for close-time size update
	mov	ax, [resolved_dir_cluster]
	push	bx
	shl	bx, 1
	mov	[cs:sft_dir_cluster + bx], ax
	mov	ax, [resolved_dir_entries]
	mov	[cs:sft_dir_entries + bx], ax
	mov	word [cs:sft_devinfo + bx], 0	; Disk file
	pop	bx
	pop	es

	; Load FAT (needed for cluster chain traversal)
	call	read_fat

	pop	bx			; Handle number
	mov	ax, bx			; Return handle in AX

	mov	ds, [cs:.i21_3d_ds]
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE	; Clear CF
	pop	bp
	iret

.i21_3d_mode	db	0
.i21_3d_handle	dw	0
.i21_3d_ds	dw	0
.i21_3d_no_handle:
	pop	bx
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 4			; Too many open files
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=3E: Close file ---
; Input: BX = handle
.i21_3e:
	cmp	bx, MAX_HANDLES
	jae	.i21_3e_bad
	push	ax
	push	cx
	push	si
	push	di
	push	ds
	push	es

	; Look up SFT index from JFT
	mov	es, [cs:exec_seg]
	mov	al, [es:0x18 + bx]
	cmp	al, 0xFF
	je	.i21_3e_just_close_noref	; Already closed
	; Mark JFT entry as closed
	mov	byte [es:0x18 + bx], 0xFF
	; Decrement refcount
	xor	ah, ah
	mov	si, ax			; SI = SFT index
	cmp	byte [cs:sft_refcount + si], 0
	je	.i21_3e_just_close_noref
	dec	byte [cs:sft_refcount + si]
	jnz	.i21_3e_just_close_noref ; Other handles still reference this SFT entry
	; Refcount = 0: actually close the SFT entry
	; Convert SFT index to table offset
	push	cx
	mov	cl, 4
	shl	si, cl
	pop	cx

	; Check if file was opened for write — update directory with file size
	cmp	byte [cs:file_handles + si], 2
	jb	.i21_3e_just_close	; Read-only, no update needed

	; Read the directory to find and update the file entry
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	al, [cs:file_handles + si + 1]
	mov	[resolved_drive], al
	; Re-read the directory where the file was opened
	; SI = SFT offset. SFT index = SI / 16
	push	cx
	mov	cx, si
	shr	cx, 1
	shr	cx, 1
	shr	cx, 1
	shr	cx, 1			; CX = SFT index
	shl	cx, 1			; CX = word index for sft_dir_cluster
	mov	bx, cx
	mov	ax, [cs:sft_dir_cluster + bx]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cs:sft_dir_entries + bx]
	mov	[resolved_dir_entries], ax
	pop	cx
	call	read_resolved_dir
	jc	.i21_3e_dir_fail

	; Search for entry with matching start cluster
	mov	di, dir_buffer
	mov	cx, [resolved_dir_entries]
	mov	ax, [cs:file_handles + si + 2]	; Start cluster from SFT
.i21_3e_search:
	cmp	byte [di], 0
	je	.i21_3e_not_found
	cmp	byte [di], 0xE5
	je	.i21_3e_next
	cmp	[di+26], ax
	je	.i21_3e_found
	; Also match if dir entry has cluster 0 and file size 0
	; (file was created empty, cluster allocated during write)
	cmp	word [di+26], 0
	jne	.i21_3e_next
	cmp	word [di+28], 0
	jne	.i21_3e_next
	cmp	word [di+30], 0
	jne	.i21_3e_next
	; This is an empty entry — check if only one such entry exists
	; to avoid ambiguity (skip for now, just take the first match)
	jmp	.i21_3e_found
.i21_3e_next:
	add	di, 32
	dec	cx
	jnz	.i21_3e_search
.i21_3e_not_found:
	jmp	.i21_3e_just_close
.i21_3e_dir_fail:
	jmp	.i21_3e_just_close

.i21_3e_found:
	; Update start cluster in directory entry (may have been allocated during write)
	mov	ax, [cs:file_handles + si + 2]
	mov	[di+26], ax
	; Update file size in directory entry from file pointer
	mov	ax, [cs:file_handles + si + 8]	; File pointer = actual bytes written
	mov	[di+28], ax
	mov	ax, [cs:file_handles + si + 10]
	mov	[di+30], ax
	call	write_resolved_dir

.i21_3e_just_close:
	mov	byte [cs:file_handles + si], 0	; Mark SFT entry closed
.i21_3e_just_close_noref:
	pop	es
	pop	ds
	pop	di
	pop	si
	pop	cx
	pop	ax
.i21_3e_ok:
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_3e_bad:
	mov	ax, 6			; Invalid handle
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=3F: Read from file ---
; Input: BX = handle, CX = bytes to read, DS:DX = buffer
; Output: AX = bytes actually read, CF=0
.i21_3f:
	cmp	bx, MAX_HANDLES
	jae	.i21_3f_bad

	push	bx
	push	si
	push	di
	push	es

	; Get SFT entry via JFT lookup
	call	handle_to_sft
	jc	.i21_3f_bad_pop

	; Check if this is a device (flag & 0x80)
	test	byte [cs:file_handles + si], 0x80
	jz	.i21_3f_not_device
	; Device — pop saved regs and go to stdin handler
	pop	es
	pop	di
	pop	si
	pop	bx
	jmp	.i21_3f_stdin
.i21_3f_not_device:

	; Check handle is open
	cmp	byte [cs:file_handles + si], 0
	je	.i21_3f_bad_pop

	; Save caller's DS:DX
	mov	[cs:.i21_3f_ds], ds
	mov	[cs:.i21_3f_dx], dx
	mov	[cs:.i21_3f_cx], cx

	; Switch to SHELL_SEG for FAT/disk access
	mov	ax, SHELL_SEG
	mov	ds, ax

	; How many bytes left in file?
	mov	ax, [cs:file_handles + si + 12]	; File size low
	mov	dx, [cs:file_handles + si + 14]	; File size high
	sub	ax, [cs:file_handles + si + 8]	; Subtract file pointer low
	sbb	dx, [cs:file_handles + si + 10]	; Subtract file pointer high
	; DX:AX = bytes remaining
	; Cap CX to bytes remaining
	or	dx, dx
	jnz	.i21_3f_cx_ok		; More than 64K remaining
	cmp	ax, [cs:.i21_3f_cx]
	jae	.i21_3f_cx_ok
	mov	[cs:.i21_3f_cx], ax	; Reduce to remaining
.i21_3f_cx_ok:

	; Read loop: read from current cluster, advance
	mov	cx, [cs:.i21_3f_cx]
	mov	word [cs:.i21_3f_read], 0	; Bytes read so far

	; Load FAT for cluster chain traversal
	push	si
	push	cx
	call	read_fat
	pop	cx
	pop	si

.i21_3f_read_loop:
	cmp	cx, 0
	je	.i21_3f_done

	; Read current cluster into io_buffer (preserve dir_buffer)
	mov	ax, [cs:file_handles + si + 4]	; Current cluster
	cmp	ax, 0
	je	.i21_3f_done
	cmp	ax, 0xFF8
	jae	.i21_3f_done

	mov	al, [cs:file_handles + si + 1]	; Drive
	mov	[resolved_drive], al
	mov	ax, [cs:file_handles + si + 4]
	push	cx			; Save byte count — cluster_to_chs/INT 13h clobber CX
	push	si			; Save handle offset — INT 13h may clobber SI
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, io_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	pop	si
	pop	cx
	jc	.i21_3f_done

	; Copy bytes from io_buffer + cluster_offset to caller's buffer
	mov	bx, [cs:file_handles + si + 6]	; Position in cluster
	mov	di, [cs:.i21_3f_dx]	; Dest offset in caller's buffer

.i21_3f_copy:
	cmp	cx, 0
	je	.i21_3f_advance_done
	cmp	bx, SECS_PER_CLUST * 512
	jae	.i21_3f_next_cluster

	; Copy one byte
	mov	al, [io_buffer + bx]
	push	es
	mov	es, [cs:.i21_3f_ds]
	mov	[es:di], al
	pop	es
	inc	bx
	inc	di
	dec	cx
	inc	word [cs:.i21_3f_read]
	; Advance file pointer
	add	word [cs:file_handles + si + 8], 1
	adc	word [cs:file_handles + si + 10], 0
	jmp	.i21_3f_copy

.i21_3f_next_cluster:
	; Move to next cluster in chain
	mov	ax, [cs:file_handles + si + 4]
	call	fat12_next_cluster
	mov	[cs:file_handles + si + 4], ax
	mov	word [cs:file_handles + si + 6], 0
	mov	bx, 0
	jmp	.i21_3f_read_loop

.i21_3f_advance_done:
	mov	[cs:file_handles + si + 6], bx	; Save cluster position
	mov	[cs:.i21_3f_dx], di		; Update buffer position

.i21_3f_done:
	mov	ds, [cs:.i21_3f_ds]
	mov	ax, [cs:.i21_3f_read]
	pop	es
	pop	di
	pop	si
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_3f_stdin:
	; Read from keyboard into DS:DX buffer, up to CX bytes
	push	bx
	push	si
	mov	si, dx
	xor	bx, bx			; BX = bytes read count
.i21_3f_stdin_loop:
	cmp	bx, cx
	jge	.i21_3f_stdin_done
	push	bx
	push	cx
	call	con_read_al
	pop	cx
	pop	bx
	cmp	al, 0
	je	.i21_3f_stdin_loop	; Skip extended keys
	push	ax
	call	con_write_al		; Echo
	pop	ax
	cmp	al, 0x08
	jne	.i21_3f_stdin_not_bs
	cmp	bx, 0
	je	.i21_3f_stdin_loop
	dec	bx
	dec	si
	push	ax
	mov	al, ' '
	call	con_write_al
	mov	al, 0x08
	call	con_write_al
	pop	ax
	jmp	.i21_3f_stdin_loop
.i21_3f_stdin_not_bs:
	mov	[si], al
	inc	si
	inc	bx
	cmp	al, 0x0D
	jne	.i21_3f_stdin_loop
	push	ax
	mov	al, 0x0A
	call	con_write_al
	pop	ax
	cmp	bx, cx
	jge	.i21_3f_stdin_done
	mov	byte [si], 0x0A
	inc	bx
.i21_3f_stdin_done:
	mov	ax, bx
	pop	si
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_3f_bad_pop:
	pop	es
	pop	di
	pop	si
	pop	bx
.i21_3f_bad:
	mov	ax, 6
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_3f_ds	dw	0
.i21_3f_dx	dw	0
.i21_3f_cx	dw	0
.i21_3f_read	dw	0

; --- AH=40: Write to file/device ---
; Input: BX = handle, CX = bytes, DS:DX = buffer
; Output: AX = bytes written
.i21_40:
	cmp	bx, MAX_HANDLES
	jae	.i21_40_bad

	; File write
	push	bx
	push	si
	push	di
	push	es

	; Get SFT entry via JFT lookup
	call	handle_to_sft
	jc	.i21_40_bad_pop

	; Check if this is a device (flag & 0x80)
	test	byte [cs:file_handles + si], 0x80
	jnz	.i21_40_stdout_pop	; Device → console output

	cmp	byte [cs:file_handles + si], 0
	je	.i21_40_bad_pop

	; CX=0 means truncate file at current position
	cmp	cx, 0
	jne	.i21_40_not_trunc
	; Truncate: set file size = current file pointer
	mov	ax, [cs:file_handles + si + 8]
	mov	[cs:file_handles + si + 12], ax
	mov	ax, [cs:file_handles + si + 10]
	mov	[cs:file_handles + si + 14], ax
	xor	ax, ax			; 0 bytes written
	pop	es
	pop	di
	pop	si
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_40_not_trunc:

	; Save caller state
	mov	[cs:.i21_40_ds], ds
	mov	[cs:.i21_40_dx], dx
	mov	[cs:.i21_40_cx], cx
	mov	word [cs:.i21_40_written], 0

	; Switch to SHELL_SEG
	mov	ax, SHELL_SEG
	mov	ds, ax

	; Load FAT (save SI and CX)
	push	si
	push	cx
	call	read_fat
	pop	cx
	pop	si

	mov	cx, [cs:.i21_40_cx]

.i21_40_write_loop:
	cmp	cx, 0
	je	.i21_40_write_done

	; Read current cluster into io_buffer (preserve dir_buffer)
	mov	ax, [cs:file_handles + si + 4]
	cmp	ax, 0
	je	.i21_40_need_cluster	; No cluster yet — allocate first one
	cmp	ax, 0xFF8
	jae	.i21_40_need_cluster

	mov	al, [cs:file_handles + si + 1]
	mov	[resolved_drive], al
	mov	ax, [cs:file_handles + si + 4]
	push	cx			; Save byte count BEFORE cluster_to_chs trashes CX
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, io_buffer
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	pop	cx			; Restore byte count
	jc	.i21_40_write_done

	; Copy bytes from caller's buffer into io_buffer
	mov	bx, [cs:file_handles + si + 6]	; Position in cluster
	mov	di, [cs:.i21_40_dx]

.i21_40_copy:
	cmp	cx, 0
	je	.i21_40_flush
	cmp	bx, SECS_PER_CLUST * 512
	jae	.i21_40_flush_next

	; Copy one byte from caller to cluster buffer
	push	es
	mov	es, [cs:.i21_40_ds]
	mov	al, [es:di]
	pop	es
	mov	[io_buffer + bx], al
	inc	bx
	inc	di
	dec	cx
	inc	word [cs:.i21_40_written]
	; Advance file pointer
	add	word [cs:file_handles + si + 8], 1
	adc	word [cs:file_handles + si + 10], 0
	jmp	.i21_40_copy

.i21_40_flush_next:
	; Write current cluster back, then get next
	mov	[cs:file_handles + si + 6], bx
	mov	[cs:.i21_40_dx], di

	; Write cluster from io_buffer
	mov	ax, [cs:file_handles + si + 4]
	push	cx			; Save byte count
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, io_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	pop	cx
	jc	.i21_40_write_done

	; Allocate next cluster
.i21_40_need_cluster:
	push	cx
	mov	ax, 2
.i21_40_find_cl:
	cmp	ax, 720
	jae	.i21_40_full
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.i21_40_got_cl
	inc	ax
	jmp	.i21_40_find_cl
.i21_40_got_cl:
	; AX = new free cluster
	; Mark new cluster as EOF
	push	ax
	mov	bx, 0xFFF
	call	fat12_write_cluster
	; Check if this is the first cluster (previous = 0)
	cmp	word [cs:file_handles + si + 4], 0
	je	.i21_40_first_cl
	; Link previous cluster → new
	mov	ax, [cs:file_handles + si + 4]
	pop	bx			; New cluster
	push	bx
	call	fat12_write_cluster
	jmp	.i21_40_cl_done
.i21_40_first_cl:
	; First cluster — set as start cluster too
	pop	ax
	push	ax
	mov	[cs:file_handles + si + 2], ax	; Start cluster
.i21_40_cl_done:
	call	write_fat
	pop	ax
	mov	[cs:file_handles + si + 4], ax	; Update current cluster
	mov	word [cs:file_handles + si + 6], 0
	pop	cx
	mov	bx, 0
	jmp	.i21_40_write_loop

.i21_40_full:
	pop	cx

.i21_40_flush:
	; Write current cluster back from io_buffer
	mov	[cs:file_handles + si + 6], bx
	mov	[cs:.i21_40_dx], di

	mov	ax, [cs:file_handles + si + 4]
	cmp	ax, 0xFF8
	jae	.i21_40_write_done
	push	cx			; Save byte count
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, io_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	pop	cx

.i21_40_write_done:
	; Update file size if pointer exceeds it
	mov	ax, [cs:file_handles + si + 8]	; File pointer low
	cmp	ax, [cs:file_handles + si + 12]	; Compare to size low
	mov	ax, [cs:file_handles + si + 10]	; File pointer high
	sbb	ax, [cs:file_handles + si + 14]	; Compare to size high (with borrow)
	jb	.i21_40_size_ok			; Pointer < size, no update
	; Pointer >= size: update size to match pointer
	mov	ax, [cs:file_handles + si + 8]
	mov	[cs:file_handles + si + 12], ax
	mov	ax, [cs:file_handles + si + 10]
	mov	[cs:file_handles + si + 14], ax
.i21_40_size_ok:
	mov	ds, [cs:.i21_40_ds]
	mov	ax, [cs:.i21_40_written]
	pop	es
	pop	di
	pop	si
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_40_bad_pop:
	pop	es
	pop	di
	pop	si
	pop	bx
.i21_40_bad:
	mov	ax, 6
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_40_stdout_pop:
	pop	es
	pop	di
	pop	si
	pop	bx
.i21_40_stdout:
	; Print CX bytes from DS:DX to screen
	push	si
	push	cx
	mov	si, dx
	mov	ax, cx
	push	ax
.i21_40_out_loop:
	cmp	cx, 0
	je	.i21_40_out_done
	lodsb
	push	cx
	call	con_write_al
	pop	cx
	dec	cx
	jmp	.i21_40_out_loop
.i21_40_out_done:
	pop	ax
	pop	cx
	pop	si
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_40_ds	dw	0
.i21_40_dx	dw	0
.i21_40_cx	dw	0
.i21_40_written	dw	0

; --- AH=42: Seek (move file pointer) ---
; Input: BX = handle, AL = method (0=start, 1=current, 2=end)
;        CX:DX = offset
; Output: DX:AX = new position
.i21_42:
	cmp	bx, MAX_HANDLES
	jae	.i21_42_bad
	mov	[cs:.i21_42_method], al	; Save method before AL is clobbered
	push	es
	push	si
	call	handle_to_sft
	jc	.i21_42_bad_pop

	; Validate handle is open
	cmp	byte [cs:file_handles + si], 0
	je	.i21_42_bad_pop

	; Compute absolute position based on method
	cmp	byte [cs:.i21_42_method], 0
	je	.i21_42_from_start
	cmp	byte [cs:.i21_42_method], 1
	je	.i21_42_from_current
	; Method 2: from end — position = file_size + CX:DX (CX:DX is usually negative)
	mov	ax, [cs:file_handles + si + 12]	; File size low
	add	ax, dx
	mov	[cs:file_handles + si + 8], ax
	mov	ax, [cs:file_handles + si + 14]	; File size high
	adc	ax, cx
	mov	[cs:file_handles + si + 10], ax
	jmp	.i21_42_do_seek
.i21_42_from_current:
	; Method 1: from current — position = current_pos + CX:DX
	mov	ax, [cs:file_handles + si + 8]	; Current pos low
	add	ax, dx
	mov	[cs:file_handles + si + 8], ax
	mov	ax, [cs:file_handles + si + 10]	; Current pos high
	adc	ax, cx
	mov	[cs:file_handles + si + 10], ax
	jmp	.i21_42_do_seek
.i21_42_from_start:
	; Method 0: from start — position = CX:DX
	mov	[cs:file_handles + si + 8], dx
	mov	[cs:file_handles + si + 10], cx
.i21_42_do_seek:

	; Need to recalculate current cluster from start
	; Walk the FAT chain from start cluster
	push	bx
	push	dx

	; Set resolved_drive from file handle
	mov	al, [cs:file_handles + si + 1]
	mov	[cs:resolved_drive], al

	push	si
	mov	ax, SHELL_SEG
	push	ds
	mov	ds, ax
	call	read_fat
	pop	ds
	pop	si

	mov	ax, [cs:file_handles + si + 2]	; Start cluster
	mov	[cs:file_handles + si + 4], ax	; Reset current cluster

	; Calculate how many clusters to skip
	; 32-bit divide: DX:AX / 1024
	mov	dx, [cs:file_handles + si + 10]	; Position high
	mov	ax, [cs:file_handles + si + 8]	; Position low
	mov	bx, SECS_PER_CLUST * 512
	div	bx			; AX = clusters to skip, DX = position in cluster
	mov	[cs:file_handles + si + 6], dx	; Position within cluster

	; Skip AX clusters
	mov	cx, ax
	mov	ax, [cs:file_handles + si + 4]
	jcxz	.i21_42_positioned
.i21_42_skip:
	push	cx
	push	ds
	mov	cx, SHELL_SEG
	mov	ds, cx
	call	fat12_next_cluster
	pop	ds
	pop	cx
	cmp	ax, 0xFF8
	jae	.i21_42_positioned	; Hit end of chain
	mov	[cs:file_handles + si + 4], ax
	dec	cx
	jnz	.i21_42_skip

.i21_42_positioned:
	pop	dx
	pop	bx

	; Return new position in DX:AX
	mov	ax, [cs:file_handles + si + 8]
	mov	dx, [cs:file_handles + si + 10]

	pop	si
	pop	es
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_42_bad:
	mov	ax, 6
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_42_bad_pop:
	pop	si
	pop	es
	jmp	.i21_42_bad

.i21_42_method:	db	0

; --- AH=48: Allocate memory ---
; Input: BX = paragraphs requested
; Output: AX = segment of allocated block, CF=0 on success
;         CF=1 on failure, BX = largest available block
.i21_48:
	call	alloc_mem_core
	jc	.i21_48_int_fail
	; Success: AX = segment
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE	; Clear CF in saved flags
	pop	bp
	iret
.i21_48_int_fail:
	; Fail: AX = 8, BX = largest available
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001	; Set CF in saved flags
	pop	bp
	iret

; --- AH=49: Free memory ---
; Input: ES = segment to free
; Output: CF=0 on success
.i21_49:
	push	ax
	push	es
	; MCB is at ES-1
	mov	ax, es
	dec	ax
	mov	es, ax
	cmp	byte [es:0x00], 'M'
	je	.i21_49_ok
	cmp	byte [es:0x00], 'Z'
	je	.i21_49_ok
	; Invalid MCB
	pop	es
	pop	ax
	mov	ax, 9			; Invalid MCB
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret
.i21_49_ok:
	mov	word [es:0x01], 0	; Mark as free
	; Try to merge with next block if also free
	call	.mcb_merge_free
	pop	es
	pop	ax
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=4A: Resize memory block ---
; Input: ES = segment of block, BX = new size in paragraphs
; Output: CF=0 on success, CF=1 on failure (BX = max available)
.i21_4a:
	push	ax
	push	cx
	push	es
	mov	ax, es
	dec	ax
	mov	es, ax			; ES = MCB
	mov	cx, [es:0x03]		; Current size
	cmp	bx, cx
	jbe	.i21_4a_shrink
	; Growing — not supported (would need to check next block)
	mov	bx, cx			; Return current size as max
	pop	es
	pop	cx
	pop	ax
	mov	ax, 8
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret
.i21_4a_shrink:
	; Shrinking — adjust size, create free block after
	; CX = old size, BX = new size, ES = MCB
	; If equal, nothing to do
	cmp	bx, cx
	je	.i21_4a_done
	; Need at least 1 para for new MCB header
	mov	ax, cx
	sub	ax, bx			; AX = old - new = freed paras
	cmp	ax, 1
	jbe	.i21_4a_done		; Not enough room for a free MCB
	; Set new size
	mov	[es:0x03], bx
	; Save original block type
	mov	dl, [es:0x00]
	mov	byte [es:0x00], 'M'	; This block is no longer last
	; Create free MCB after this block
	mov	ax, es
	add	ax, bx
	inc	ax			; AX = segment of new free MCB
	push	es
	mov	es, ax
	mov	[es:0x00], dl		; Inherit original type ('M' or 'Z')
	mov	word [es:0x01], 0	; Free (no owner)
	mov	ax, cx
	sub	ax, bx
	dec	ax			; Remaining = old_size - new_size - 1 (MCB header)
	mov	[es:0x03], ax		; Set free block size
	pop	es
.i21_4a_done:
	pop	es
	pop	cx
	pop	ax
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- MCB helper: merge adjacent free blocks ---
.mcb_merge_free:
	push	ax
	push	bx
	push	es
	mov	ax, [cs:mcb_first]
.mcb_merge_walk:
	mov	es, ax
	cmp	byte [es:0x00], 'Z'
	je	.mcb_merge_done
	cmp	byte [es:0x00], 'M'
	jne	.mcb_merge_done
	cmp	word [es:0x01], 0	; Current free?
	jne	.mcb_merge_next
	; Check if next is also free
	mov	bx, [es:0x03]
	push	ax
	add	ax, bx
	inc	ax
	push	es
	mov	es, ax
	cmp	word [es:0x01], 0	; Next block free?
	jne	.mcb_merge_no
	; Merge: absorb next block
	mov	bx, [es:0x03]		; Next block size
	mov	al, [es:0x00]		; Next block type (M or Z)
	pop	es			; Back to current MCB
	add	bx, 1			; +1 for absorbed MCB paragraph
	add	[es:0x03], bx		; Grow current block
	mov	[es:0x00], al		; Inherit type
	pop	ax
	jmp	.mcb_merge_walk		; Check again (might merge more)
.mcb_merge_no:
	pop	es
	pop	ax
.mcb_merge_next:
	mov	bx, [es:0x03]
	add	ax, bx
	inc	ax
	jmp	.mcb_merge_walk
.mcb_merge_done:
	pop	es
	pop	bx
	pop	ax
	ret

; --- AH=19: Get current drive ---
; Returns AL = current drive (0=A, 1=B, ...)
.i21_19:
	mov	al, [cs:cur_drive]
	iret

; --- AH=1A: Set DTA address ---
; DS:DX = new DTA
.i21_1a:
	mov	[cs:dta_seg], ds
	mov	[cs:dta_off], dx
	iret

; --- AH=2A: Get date ---
; Returns CX=year, DH=month, DL=day, AL=day of week
.i21_2a:
	push	bx
	mov	ah, 0x04
	int	0x1A
	jc	.i21_2a_default
	; CH=century BCD, CL=year BCD, DH=month BCD, DL=day BCD
	push	dx
	mov	al, ch
	call	.bcd_to_bin_i21
	mov	bh, al		; century
	mov	al, cl
	call	.bcd_to_bin_i21
	mov	bl, al		; year
	xor	ah, ah
	mov	al, bh
	mov	cl, 100
	mul	cl
	xor	ch, ch
	mov	cl, bl
	add	ax, cx
	mov	cx, ax		; CX = full year
	pop	dx
	push	cx
	mov	al, dh
	call	.bcd_to_bin_i21
	mov	dh, al		; month
	mov	al, dl
	call	.bcd_to_bin_i21
	mov	dl, al		; day
	pop	cx
	xor	al, al		; Day of week = 0 (not computed)
	pop	bx
	iret
.i21_2a_default:
	mov	cx, 2026
	mov	dh, 4
	mov	dl, 14
	xor	al, al
	pop	bx
	iret

; --- AH=2C: Get time ---
; Returns CH=hour, CL=minute, DH=second, DL=hundredths
.i21_2c:
	mov	ah, 0x02
	int	0x1A
	jc	.i21_2c_default
	; CH=hour BCD, CL=min BCD, DH=sec BCD
	push	bx
	mov	al, ch
	call	.bcd_to_bin_i21
	mov	bh, al		; hour
	mov	al, cl
	call	.bcd_to_bin_i21
	mov	bl, al		; minute
	mov	al, dh
	call	.bcd_to_bin_i21
	mov	ch, bh		; hour
	mov	cl, bl		; minute
	mov	dh, al		; second
	xor	dl, dl		; hundredths = 0
	pop	bx
	iret
.i21_2c_default:
	mov	cx, 0x0C00	; 12:00
	xor	dx, dx		; 0 seconds
	iret

; BCD to binary helper for INT 21h handlers
.bcd_to_bin_i21:
	push	cx
	mov	cl, al
	shr	al, 1
	shr	al, 1
	shr	al, 1
	shr	al, 1
	mov	ch, 10
	mul	ch
	and	cl, 0x0F
	add	al, cl
	pop	cx
	ret

; --- AH=2F: Get DTA address ---
; Returns ES:BX = current DTA
.i21_2f:
	mov	es, [cs:dta_seg]
	mov	bx, [cs:dta_off]
	iret

; --- AH=36: Get disk free space ---
; Input: DL = drive (0=default, 1=A, 2=B)
; Returns: AX=sectors per cluster, BX=free clusters, CX=bytes per sector, DX=total clusters
.i21_36:
	push	si
	push	di
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Set drive: DL=0 default, DL=1 A:, DL=2 B:
	or	dl, dl
	jnz	.i21_36_has_drive
	mov	dl, [cur_drive]
	jmp	.i21_36_set_drive
.i21_36_has_drive:
	dec	dl			; 1-based to 0-based
.i21_36_set_drive:
	mov	[resolved_drive], dl
	; Read FAT to count free clusters
	push	dx
	call	read_fat
	pop	dx
	jc	.i21_36_err
	; Count free clusters (cluster 2 through max)
	xor	bx, bx			; Free count
	mov	ax, 2			; Start at cluster 2
	mov	di, (TOTAL_SECS - DATA_START_SEC) / SECS_PER_CLUST + 2 ; Max cluster
.i21_36_count:
	cmp	ax, di
	jae	.i21_36_counted
	push	ax
	push	bx
	call	fat12_read_cluster	; AX = cluster value
	cmp	ax, 0
	pop	bx
	pop	ax
	jne	.i21_36_not_free
	inc	bx
.i21_36_not_free:
	inc	ax
	jmp	.i21_36_count
.i21_36_counted:
	pop	ds
	pop	di
	pop	si
	mov	ax, SECS_PER_CLUST
	mov	cx, 512
	mov	dx, (TOTAL_SECS - DATA_START_SEC) / SECS_PER_CLUST
	iret
.i21_36_err:
	pop	ds
	pop	di
	pop	si
	mov	ax, 0xFFFF		; Error
	iret

; --- AH=44: IOCTL ---
; AL=0: Get device info for handle BX
; Returns DX = device info word
.i21_44:
	cmp	al, 0
	je	.i21_44_get
	cmp	al, 1
	je	.i21_44_set
	cmp	al, 6
	je	.i21_44_input_ready
	cmp	al, 7
	je	.i21_44_output_ready
	cmp	al, 8
	je	.i21_44_removable
	; Other subfunctions — return error
	mov	ax, 1
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_44_get:
	; AL=0: Get device info for handle BX
	cmp	bx, MAX_HANDLES
	jae	.i21_44_bad_handle
	push	si
	call	handle_to_sft
	jc	.i21_44_bad_handle_pop
	; SI = SFT offset (index * 16). Get SFT index for devinfo lookup
	push	bx
	mov	bx, si
	shr	bx, 1
	shr	bx, 1
	shr	bx, 1			; BX = SFT index * 2 (word offset)
	mov	dx, [cs:sft_devinfo + bx]
	pop	bx
	pop	si
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_44_bad_handle_pop:
	pop	si
	jmp	.i21_44_bad_handle
.i21_44_bad_handle:
	mov	ax, 6			; Invalid handle
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_44_set:
	; AL=1: Set device info — ignore, return success
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_44_input_ready:
	; AL=6: Check input status — resolve via SFT
	push	si
	call	handle_to_sft
	jc	.i21_44_input_err
	test	byte [cs:file_handles + si], 0x80
	pop	si
	jz	.i21_44_input_file
	; Device: check keyboard buffer via INT 16h AH=01
	push	ax
	mov	ah, 0x01
	int	0x16
	jz	.i21_44_not_ready
	pop	ax
	mov	al, 0xFF		; Ready
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_44_not_ready:
	pop	ax
	mov	al, 0x00		; Not ready
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_44_input_err:
	pop	si
	jmp	.i21_44_bad_handle
.i21_44_input_file:
	mov	al, 0xFF		; Files always ready
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_44_output_ready:
	; AL=7: Check output status — resolve via SFT
	push	si
	call	handle_to_sft
	pop	si
	; Device or file — output always ready
	mov	al, 0xFF
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_44_removable:
	; AL=8: Check if removable media
	; BL = drive (0=A, 1=B)
	; Returns: AX=0 removable, AX=1 fixed
	xor	ax, ax			; 0 = removable (floppy)
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=45: Duplicate handle (DUP) ---
; Input: BX = handle to duplicate
; Returns: AX = new handle, CF=0 success
.i21_45:
	cmp	bx, MAX_HANDLES
	jae	.i21_45_err
	; Get the SFT index for the source handle from the JFT
	push	cx
	push	es
	mov	es, [cs:exec_seg]
	mov	al, [es:0x18 + bx]	; AL = SFT index of source handle
	cmp	al, 0xFF
	je	.i21_45_no_handle
	; Find a free JFT slot (handle 5+)
	mov	di, 5
.i21_45_find:
	cmp	di, MAX_HANDLES
	jae	.i21_45_no_handle
	cmp	byte [es:0x18 + di], 0xFF  ; Free slot?
	je	.i21_45_got
	inc	di
	jmp	.i21_45_find
.i21_45_got:
	; Point new JFT entry to same SFT index
	mov	[es:0x18 + di], al	; New handle → same SFT entry
	; Increment refcount
	push	bx
	xor	ah, ah
	mov	bx, ax			; BX = SFT index
	inc	byte [cs:sft_refcount + bx]
	pop	bx
	; Return new handle number in AX
	mov	ax, di
	pop	es
	pop	cx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_45_no_handle:
	pop	es
	pop	cx
.i21_45_err:
	mov	ax, 4			; Too many open files
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=46: Force duplicate handle (DUP2) ---
; Input: BX = source handle, CX = target handle
; Target handle is closed if open, then made a copy of source
.i21_46:
	cmp	bx, MAX_HANDLES
	jae	.i21_46_err
	cmp	cx, MAX_HANDLES
	jae	.i21_46_err
	; DUP2 with same handle = no-op success
	cmp	bx, cx
	je	.i21_46_noop
	push	es
	mov	es, [cs:exec_seg]
	; Get SFT index of source handle
	mov	al, [es:0x18 + bx]
	cmp	al, 0xFF
	je	.i21_46_err_pop
	; Decrement refcount of target's old SFT entry if it was open
	push	bx
	xor	ah, ah
	mov	di, cx
	mov	bl, [es:0x18 + di]
	cmp	bl, 0xFF
	je	.i21_46_target_closed
	xor	bh, bh
	cmp	byte [cs:sft_refcount + bx], 0
	je	.i21_46_target_closed
	dec	byte [cs:sft_refcount + bx]
	jnz	.i21_46_target_closed
	; Refcount hit 0 — mark SFT entry closed (but not devices)
	push	cx
	mov	cl, 4
	shl	bx, cl
	test	byte [cs:file_handles + bx], 0x80
	jnz	.i21_46_skip_clear	; Don't close device SFTs
	mov	byte [cs:file_handles + bx], 0
.i21_46_skip_clear:
	pop	cx
.i21_46_target_closed:
	pop	bx
	; Point target JFT entry to source's SFT index
	mov	di, cx
	mov	[es:0x18 + di], al
	; Increment source's refcount
	push	bx
	xor	ah, ah
	mov	bx, ax
	inc	byte [cs:sft_refcount + bx]
	pop	bx
	pop	es
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_46_err_pop:
	pop	es
.i21_46_noop:
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_46_err:
	mov	ax, 6			; Invalid handle
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=47: Get current directory ---
; Input: DL = drive (0=default, 1=A, 2=B), DS:SI = 64-byte buffer
; Returns: buffer filled with current path (no leading \)
.i21_47:
	push	ax
	push	di
	; Determine which drive's path to return
	; DL: 0=default, 1=A, 2=B
	or	dl, dl
	jnz	.i21_47_specific
	; Default drive — use cur_dir_path
	mov	di, cur_dir_path
	jmp	.i21_47_do_copy
.i21_47_specific:
	cmp	dl, 1
	je	.i21_47_drv_a
	cmp	dl, 2
	je	.i21_47_drv_b
	; Invalid drive — return empty string
	mov	byte [si], 0
	jmp	.i21_47_done_direct
.i21_47_drv_a:
	mov	di, drv_a_path
	jmp	.i21_47_do_copy
.i21_47_drv_b:
	mov	di, drv_b_path
.i21_47_do_copy:
	; Copy from CS:DI to DS:SI
	push	si
.i21_47_copy:
	mov	al, [cs:di]
	mov	[si], al
	or	al, al
	jz	.i21_47_done
	inc	si
	inc	di
	jmp	.i21_47_copy
.i21_47_done:
	pop	si
.i21_47_done_direct:
	pop	di
	pop	ax
	; Clear carry
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=4D: Get return code ---
; Returns AX = return code of last program
.i21_4d:
	mov	ax, [cs:last_return_code]
	iret

; --- AH=62: Get PSP segment ---
; Returns BX = PSP segment
.i21_62:
	mov	bx, [cs:exec_seg]
	iret

; --- AH=0D: Disk reset (flush buffers) ---
; No-op since we write through
.i21_0d:
	iret

; --- AH=37: Get/set switch character ---
; AL=0: get → DL=switch char, AL=1: set (ignored)
.i21_37:
	cmp	al, 0
	jne	.i21_37_set
	mov	dl, '/'
	iret
.i21_37_set:
	iret

; --- AH=0E: Set current drive ---
; Input: DL = drive (0=A, 1=B, ...)
; Returns: AL = number of drives
.i21_0e:
	cmp	dl, 2
	jae	.i21_0e_done
	cmp	dl, [cs:cur_drive]
	je	.i21_0e_done		; Same drive, no switch needed
	; Save current drive state, switch, load new state
	push	ds
	push	ax
	mov	ax, SHELL_SEG
	mov	ds, ax
	call	save_drive_state
	mov	[cur_drive], dl
	mov	al, dl
	call	load_drive_state
	pop	ax
	pop	ds
.i21_0e_done:
	mov	al, 2			; We support 2 drives
	iret

; --- AH=29: Parse filename (FCB) ---
; Input: DS:SI = command line, ES:DI = FCB buffer
; Returns: AL = 0 if valid, DS:SI advanced
; Simplified: just fill FCB with spaces and return success
.i21_29:
	push	cx
	push	di
	; Clear FCB (37 bytes)
	push	ax
	mov	cx, 37
	xor	al, al
	rep	stosb
	pop	ax
	pop	di
	; Skip leading spaces
.i21_29_skip:
	mov	al, [si]
	cmp	al, ' '
	jne	.i21_29_parse
	inc	si
	jmp	.i21_29_skip
.i21_29_parse:
	; Check for drive letter
	cmp	byte [si+1], ':'
	jne	.i21_29_no_drive
	mov	al, [si]
	cmp	al, 'a'
	jb	.i21_29_drv_up
	sub	al, 0x20
.i21_29_drv_up:
	sub	al, 'A' - 1		; 1=A, 2=B
	mov	[es:di], al
	add	si, 2
.i21_29_no_drive:
	; Fill name (8 chars) with spaces first
	push	di
	add	di, 1
	push	cx
	mov	cx, 11
	mov	al, ' '
	rep	stosb
	pop	cx
	pop	di
	; Copy filename
	push	di
	add	di, 1
	mov	cx, 8
.i21_29_name:
	mov	al, [si]
	cmp	al, 0
	je	.i21_29_done
	cmp	al, ' '
	je	.i21_29_done
	cmp	al, 0x0D
	je	.i21_29_done
	cmp	al, '.'
	je	.i21_29_dot
	cmp	al, 'a'
	jb	.i21_29_store
	cmp	al, 'z'
	ja	.i21_29_store
	sub	al, 0x20
.i21_29_store:
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_29_name
	; Skip to dot
.i21_29_skip_name:
	cmp	byte [si], '.'
	je	.i21_29_dot
	cmp	byte [si], 0
	je	.i21_29_done
	cmp	byte [si], ' '
	je	.i21_29_done
	inc	si
	jmp	.i21_29_skip_name
.i21_29_dot:
	inc	si			; skip '.'
	pop	di
	push	di
	add	di, 9			; extension at FCB+9
	mov	cx, 3
.i21_29_ext:
	mov	al, [si]
	cmp	al, 0
	je	.i21_29_done
	cmp	al, ' '
	je	.i21_29_done
	cmp	al, 0x0D
	je	.i21_29_done
	cmp	al, 'a'
	jb	.i21_29_ext_store
	cmp	al, 'z'
	ja	.i21_29_ext_store
	sub	al, 0x20
.i21_29_ext_store:
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_29_ext
.i21_29_done:
	pop	di
	pop	cx
	xor	al, al			; Success
	iret

; --- AH=39: Create directory ---
; Input: DS:DX = ASCIIZ pathname
; Returns: CF=0 success, CF=1 AX=error
.i21_39:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Copy path from caller's DS:DX to shell cmd_buffer
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_39_copy:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_39_copied
	inc	di
	dec	cx
	jnz	.i21_39_copy
.i21_39_copied:
	pop	si
	; Switch to shell DS
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Use resolve_path + mkdir logic
	call	resolve_path
	jc	.i21_39_err
	call	read_resolved_dir
	jc	.i21_39_err
	; Check duplicate
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_39_dup:
	mov	al, [si]
	cmp	al, 0
	je	.i21_39_dup_ok
	cmp	al, 0xE5
	je	.i21_39_dup_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_39_exists
.i21_39_dup_next:
	add	si, 32
	dec	cx
	jnz	.i21_39_dup
.i21_39_dup_ok:
	; Find free entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_39_free:
	mov	al, [si]
	cmp	al, 0
	je	.i21_39_free_found
	cmp	al, 0xE5
	je	.i21_39_free_found
	add	si, 32
	dec	cx
	jnz	.i21_39_free
	jmp	.i21_39_err		; Dir full
.i21_39_free_found:
	mov	ax, si
	sub	ax, dir_buffer
	mov	[copy_dest_dir], ax
	; Find free cluster
	call	read_fat
	jc	.i21_39_err
	mov	ax, 2
.i21_39_find_cl:
	cmp	ax, 720
	jae	.i21_39_err
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.i21_39_got_cl
	inc	ax
	jmp	.i21_39_find_cl
.i21_39_got_cl:
	mov	[copy_dest_cl], ax
	mov	bx, 0xFFF
	call	fat12_write_cluster
	call	write_fat
	jc	.i21_39_err
	; Get timestamp
	call	get_fat_timestamp
	; Init new dir with . and ..
	mov	di, dir_buffer
	mov	cx, SECS_PER_CLUST * 512
	xor	al, al
	rep	stosb
	mov	di, dir_buffer
	mov	byte [di], '.'
	mov	cx, 10
	mov	al, ' '
	push	di
	inc	di
	rep	stosb
	pop	di
	mov	byte [di+11], 0x10
	mov	ax, [cur_fat_time]
	mov	[di+22], ax
	mov	ax, [cur_fat_date]
	mov	[di+24], ax
	mov	ax, [copy_dest_cl]
	mov	[di+26], ax
	add	di, 32
	mov	byte [di], '.'
	mov	byte [di+1], '.'
	mov	cx, 9
	mov	al, ' '
	push	di
	add	di, 2
	rep	stosb
	pop	di
	mov	byte [di+11], 0x10
	mov	ax, [cur_fat_time]
	mov	[di+22], ax
	mov	ax, [cur_fat_date]
	mov	[di+24], ax
	mov	ax, [resolved_dir_cluster]
	mov	[di+26], ax
	; Write new dir data
	mov	ax, [copy_dest_cl]
	call	cluster_to_chs
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	bx, dir_buffer
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	mov	dl, [resolved_drive]
	int	0x13
	jc	.i21_39_err
	; Re-read parent and add entry
	call	read_resolved_dir
	jc	.i21_39_err
	mov	di, dir_buffer
	add	di, [copy_dest_dir]
	mov	si, exec_fname
	mov	cx, 11
	rep	movsb
	mov	byte [di], 0x10
	inc	di
	mov	cx, 10
	xor	al, al
	rep	stosb
	mov	ax, [cur_fat_time]
	stosw
	mov	ax, [cur_fat_date]
	stosw
	mov	ax, [copy_dest_cl]
	stosw
	xor	ax, ax
	stosw
	stosw
	call	write_resolved_dir
	jc	.i21_39_err
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE	; Clear CF
	pop	bp
	iret
.i21_39_exists:
.i21_39_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 5			; Access denied
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001	; Set CF
	pop	bp
	iret

; --- AH=3A: Remove directory ---
; Input: DS:DX = ASCIIZ pathname
; Returns: CF=0 success, CF=1 AX=error
.i21_3a:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Copy path from caller
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_3a_copy:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_3a_copied
	inc	di
	dec	cx
	jnz	.i21_3a_copy
.i21_3a_copied:
	pop	si
	mov	ax, SHELL_SEG
	mov	ds, ax
	call	resolve_path
	jc	.i21_3a_err
	call	read_resolved_dir
	jc	.i21_3a_err
	; Find the directory entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_3a_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3a_err
	cmp	al, 0xE5
	je	.i21_3a_next
	test	byte [si+11], 0x10
	jz	.i21_3a_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_3a_found
.i21_3a_next:
	add	si, 32
	dec	cx
	jnz	.i21_3a_search
	jmp	.i21_3a_err
.i21_3a_found:
	; Save entry offset and cluster
	mov	ax, si
	sub	ax, dir_buffer
	mov	[copy_dest_dir], ax
	mov	ax, [si+26]
	mov	[copy_dest_cl], ax
	; Check it's not . or ..
	cmp	byte [si], '.'
	jne	.i21_3a_not_dot
	cmp	byte [si+1], ' '
	je	.i21_3a_err
	cmp	byte [si+1], '.'
	jne	.i21_3a_not_dot
	cmp	byte [si+2], ' '
	je	.i21_3a_err
.i21_3a_not_dot:
	; Check directory is empty
	push	word [resolved_dir_cluster]
	push	word [resolved_dir_entries]
	mov	ax, [copy_dest_cl]
	mov	[resolved_dir_cluster], ax
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
	call	read_resolved_dir
	jc	.i21_3a_err_pop
	mov	si, dir_buffer
	mov	cx, SECS_PER_CLUST * 512 / 32
.i21_3a_check:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3a_empty
	cmp	al, 0xE5
	je	.i21_3a_check_next
	cmp	al, '.'
	jne	.i21_3a_not_empty
	cmp	byte [si+1], ' '
	je	.i21_3a_check_next
	cmp	byte [si+1], '.'
	jne	.i21_3a_not_empty
	cmp	byte [si+2], ' '
	je	.i21_3a_check_next
	jmp	.i21_3a_not_empty
.i21_3a_check_next:
	add	si, 32
	dec	cx
	jnz	.i21_3a_check
.i21_3a_empty:
	pop	ax
	mov	[resolved_dir_entries], ax
	pop	ax
	mov	[resolved_dir_cluster], ax
	; Free cluster
	call	read_fat
	jc	.i21_3a_err
	mov	ax, [copy_dest_cl]
	mov	bx, 0
	call	fat12_write_cluster
	call	write_fat
	jc	.i21_3a_err
	; Re-read parent and mark deleted
	call	read_resolved_dir
	jc	.i21_3a_err
	mov	si, dir_buffer
	add	si, [copy_dest_dir]
	mov	byte [si], 0xE5
	call	write_resolved_dir
	jc	.i21_3a_err
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_3a_not_empty:
	pop	ax
	pop	ax
.i21_3a_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 5
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret
.i21_3a_err_pop:
	pop	ax
	pop	ax
	jmp	.i21_3a_err

; --- AH=3B: Change directory ---
; Input: DS:DX = ASCIIZ pathname
; Returns: CF=0 success, CF=1 AX=error
.i21_3b:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Copy path from caller's DS:DX
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_3b_copy:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_3b_copied
	inc	di
	dec	cx
	jnz	.i21_3b_copy
.i21_3b_copied:
	pop	si
	mov	ax, SHELL_SEG
	mov	ds, ax
	call	resolve_path
	jc	.i21_3b_err
	; If exec_fname blank, resolved_dir_cluster is target
	cmp	byte [exec_fname], ' '
	je	.i21_3b_set
	; Look up as subdir
	call	read_resolved_dir
	jc	.i21_3b_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_3b_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_3b_err
	cmp	al, 0xE5
	je	.i21_3b_next
	test	byte [si+11], 0x10
	jz	.i21_3b_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_3b_found
.i21_3b_next:
	add	si, 32
	dec	cx
	jnz	.i21_3b_search
	jmp	.i21_3b_err
.i21_3b_found:
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	cmp	ax, 0
	jne	.i21_3b_sub
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	jmp	.i21_3b_set
.i21_3b_sub:
	mov	word [resolved_dir_entries], SECS_PER_CLUST * 512 / 32
.i21_3b_set:
	mov	ax, [resolved_dir_cluster]
	mov	[cur_dir_cluster], ax
	mov	ax, [resolved_dir_entries]
	mov	[cur_dir_entries], ax
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_3b_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 3			; Path not found
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=41: Delete file ---
; Input: DS:DX = ASCIIZ filename
; Returns: CF=0 success, CF=1 AX=error
.i21_41:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Copy filename from caller
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_41_copy:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_41_copied
	inc	di
	dec	cx
	jnz	.i21_41_copy
.i21_41_copied:
	pop	si
	mov	ax, SHELL_SEG
	mov	ds, ax
	call	resolve_path
	jc	.i21_41_err
	call	read_resolved_dir
	jc	.i21_41_err
	; Find the file
	mov	ax, SHELL_SEG
	mov	es, ax			; ES = SHELL_SEG for cmpsb
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_41_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_41_not_found
	cmp	al, 0xE5
	je	.i21_41_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_41_found
.i21_41_next:
	add	si, 32
	dec	cx
	jnz	.i21_41_search
.i21_41_not_found:
	jmp	.i21_41_err
.i21_41_found:
	; Save cluster, mark deleted
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	mov	byte [si], 0xE5
	call	write_resolved_dir
	jc	.i21_41_err
	; Free FAT chain
	call	read_fat
	jc	.i21_41_err
	mov	ax, [exec_cluster]
.i21_41_free:
	cmp	ax, 0x002
	jb	.i21_41_free_done
	cmp	ax, 0xFF8
	jae	.i21_41_free_done
	push	ax
	call	fat12_next_cluster
	mov	[exec_cluster], ax
	pop	ax
	mov	bx, 0x000
	call	fat12_write_cluster
	mov	ax, [exec_cluster]
	jmp	.i21_41_free
.i21_41_free_done:
	call	write_fat
	jc	.i21_41_err
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_41_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 2			; File not found
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=43: Get/set file attributes ---
; Input: AL=0 get, AL=1 set, DS:DX = filename, CX = attrs (for set)
; Returns: CX = attributes (for get), CF on error
.i21_43:
	cmp	al, 0
	je	.i21_43_get
	; Set: just return success (ignore)
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_43_get:
	; Return normal file attributes
	mov	cx, 0x0020		; Archive
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=4E: FindFirst ---
; Input: DS:DX = ASCIIZ filespec (with wildcards), CX = search attributes
; Returns: CF=0 and DTA filled, CF=1 AX=error
; DTA format: 21 bytes reserved, 1 byte attr, 2 bytes time, 2 bytes date,
;             4 bytes size, 13 bytes ASCIIZ name
.i21_4e:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	[cs:.i21_4e_attr], cx	; Save search attributes
	; Copy filespec from caller's DS:DX
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_4e_copy:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_4e_copied
	inc	di
	dec	cx
	jnz	.i21_4e_copy
.i21_4e_copied:
	pop	si
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Parse as wildcard
	mov	di, wild_pattern
	call	parse_wildcard
	; Resolve directory
	; For simple case: use current directory
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_4e_err
	; Search for first matching entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	xor	bx, bx			; Entry index
.i21_4e_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_4e_not_found
	cmp	al, 0xE5
	je	.i21_4e_next
	; Check attribute filter
	mov	al, [si+11]
	test	al, 0x08		; Skip volume labels
	jnz	.i21_4e_next
	; Match wildcard
	mov	di, wild_pattern
	call	match_wildcard
	jc	.i21_4e_next
	; Found a match — fill DTA
	; Save search state in DTA reserved area
	mov	es, [cs:dta_seg]
	mov	di, [cs:dta_off]
	; Reserved bytes 0-20: save search state
	mov	[es:di+0], bl		; Current entry index (low)
	mov	[es:di+1], bh		; Current entry index (high)
	; Copy wildcard pattern to DTA for FindNext
	push	si
	push	cx
	mov	si, wild_pattern
	mov	cx, 11
	push	di
	add	di, 2
.i21_4e_cpwild:
	mov	al, [si]
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4e_cpwild
	pop	di
	pop	cx
	pop	si
	; Attribute at offset 21
	mov	al, [si+11]
	mov	[es:di+21], al
	; Time at offset 22
	mov	ax, [si+22]
	mov	[es:di+22], ax
	; Date at offset 24
	mov	ax, [si+24]
	mov	[es:di+24], ax
	; Size at offset 26 (4 bytes)
	mov	ax, [si+28]
	mov	[es:di+26], ax
	mov	ax, [si+30]
	mov	[es:di+28], ax
	; Filename at offset 30 (13 bytes ASCIIZ)
	push	di
	add	di, 30
	; Convert 8.3 to ASCIIZ
	push	si
	mov	cx, 8
.i21_4e_fname:
	mov	al, [si]
	cmp	al, ' '
	je	.i21_4e_fname_done
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4e_fname
.i21_4e_fname_done:
	pop	si
	push	si
	add	si, 8			; Extension
	cmp	byte [si], ' '
	je	.i21_4e_no_ext
	mov	byte [es:di], '.'
	inc	di
	mov	cx, 3
.i21_4e_ext:
	mov	al, [si]
	cmp	al, ' '
	je	.i21_4e_no_ext
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4e_ext
.i21_4e_no_ext:
	mov	byte [es:di], 0		; Null terminate
	pop	si
	pop	di
	; Success
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_4e_next:
	add	si, 32
	inc	bx
	dec	cx
	jnz	.i21_4e_search
.i21_4e_not_found:
.i21_4e_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 18			; No more files
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_4e_attr:	dw	0

; --- AH=4F: FindNext ---
; Uses DTA from previous FindFirst
; Returns: CF=0 and DTA updated, CF=1 AX=18 if no more
.i21_4f:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Read search state from DTA
	mov	es, [dta_seg]
	mov	di, [dta_off]
	mov	bl, [es:di+0]
	mov	bh, [es:di+1]
	inc	bx			; Start from next entry
	; Restore wildcard pattern from DTA
	push	di
	add	di, 2
	mov	si, wild_pattern
	mov	cx, 11
.i21_4f_restore:
	mov	al, [es:di]
	mov	[si], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4f_restore
	pop	di
	; Re-read directory (save BX — read_resolved_dir clobbers it)
	push	bx
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	pop	bx
	jc	.i21_4f_err
	; Restore ES:DI to DTA (read_resolved_dir clobbered ES)
	mov	es, [dta_seg]
	mov	di, [dta_off]
	; Skip to entry BX
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	; Skip BX entries
	mov	ax, bx
	cmp	ax, cx
	jae	.i21_4f_err		; Past end
	push	bx
	mov	bx, 32
	mul	bx
	pop	bx
	add	si, ax
	sub	cx, bx			; Remaining entries
	or	cx, cx
	jz	.i21_4f_err
	; Search from here
.i21_4f_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_4f_err
	cmp	al, 0xE5
	je	.i21_4f_next
	test	byte [si+11], 0x08
	jnz	.i21_4f_next
	push	di
	mov	di, wild_pattern
	call	match_wildcard
	pop	di
	jc	.i21_4f_next
	; Match — update DTA
	mov	[es:di+0], bl		; Save entry index
	mov	[es:di+1], bh
	mov	al, [si+11]
	mov	[es:di+21], al
	mov	ax, [si+22]
	mov	[es:di+22], ax
	mov	ax, [si+24]
	mov	[es:di+24], ax
	mov	ax, [si+28]
	mov	[es:di+26], ax
	mov	ax, [si+30]
	mov	[es:di+28], ax
	; Convert filename
	push	di
	add	di, 30
	push	si
	mov	cx, 8
.i21_4f_fname:
	mov	al, [si]
	cmp	al, ' '
	je	.i21_4f_fname_done
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4f_fname
.i21_4f_fname_done:
	pop	si
	push	si
	add	si, 8
	cmp	byte [si], ' '
	je	.i21_4f_no_ext
	mov	byte [es:di], '.'
	inc	di
	mov	cx, 3
.i21_4f_ext:
	mov	al, [si]
	cmp	al, ' '
	je	.i21_4f_no_ext
	mov	[es:di], al
	inc	si
	inc	di
	dec	cx
	jnz	.i21_4f_ext
.i21_4f_no_ext:
	mov	byte [es:di], 0
	pop	si
	pop	di
	; Success
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

.i21_4f_next:
	add	si, 32
	inc	bx
	dec	cx
	jnz	.i21_4f_search
.i21_4f_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 18			; No more files
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

; --- AH=56: Rename file ---
; Input: DS:DX = old name, ES:DI = new name
; Returns: CF=0 success, CF=1 AX=error
.i21_56:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Save new name pointer (ES:DI from caller)
	mov	[cs:.i21_56_new_off], di
	mov	[cs:.i21_56_new_seg], es
	; Copy old filename from caller's DS:DX
	mov	si, dx
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, cmd_buffer
	pop	ds
	push	di
	mov	cx, 78
.i21_56_copy_old:
	lodsb
	push	ds
	mov	bx, SHELL_SEG
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_56_old_done
	inc	di
	dec	cx
	jnz	.i21_56_copy_old
.i21_56_old_done:
	pop	si
	mov	ax, SHELL_SEG
	mov	ds, ax
	call	resolve_path
	jc	.i21_56_err
	; Save old 8.3 name
	mov	si, exec_fname
	mov	di, copy_src_name
	mov	cx, 11
	rep	movsb
	; Parse new name
	mov	es, [.i21_56_new_seg]
	mov	si, [.i21_56_new_off]
	; Copy new name to cmd_buffer
	push	ds
	mov	ax, [.i21_56_new_seg]
	mov	ds, ax
	mov	di, cmd_buffer
	mov	bx, SHELL_SEG
	push	di
	mov	cx, 78
.i21_56_copy_new:
	lodsb
	push	ds
	mov	ds, bx
	mov	[di], al
	pop	ds
	or	al, al
	jz	.i21_56_new_done
	inc	di
	dec	cx
	jnz	.i21_56_copy_new
.i21_56_new_done:
	pop	si
	pop	ds
	; Parse new name into exec_fname
	mov	di, exec_fname
	call	parse_83_filename
	; Save new 8.3 name
	mov	si, exec_fname
	mov	di, ren_new_fname
	mov	cx, 11
	rep	movsb
	; Restore old name
	mov	si, copy_src_name
	mov	di, exec_fname
	mov	cx, 11
	rep	movsb
	; Read directory, find old name, rename it
	call	read_resolved_dir
	jc	.i21_56_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_56_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_56_err
	cmp	al, 0xE5
	je	.i21_56_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_56_found
.i21_56_next:
	add	si, 32
	dec	cx
	jnz	.i21_56_search
	jmp	.i21_56_err
.i21_56_found:
	; Overwrite the 8.3 name with new name
	mov	di, si
	mov	si, ren_new_fname
	mov	cx, 11
	rep	movsb
	call	write_resolved_dir
	jc	.i21_56_err
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_56_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	ax, 2
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret
.i21_56_new_off:	dw	0
.i21_56_new_seg:	dw	0

; --- AH=57: Get/set file date/time ---
; Input: AL=0 get, AL=1 set, BX=handle
; Returns: CX=time, DX=date (for get)
.i21_57:
	cmp	al, 0
	jne	.i21_57_set
	; Get: return zeros (no timestamp tracking per handle)
	xor	cx, cx
	xor	dx, dx
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_57_set:
	; Set: ignore, return success
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=0F: Open file (FCB) ---
; Input: DS:DX = unopened FCB
; Returns: AL=0 success, AL=FF not found
.i21_0f:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	; Read FCB drive, name from caller's DS:DX
	mov	si, dx
	; Get drive (0=default, 1=A, 2=B)
	mov	al, [si]
	or	al, al
	jnz	.i21_0f_has_drive
	mov	al, [cs:cur_drive]
	inc	al			; Make 1-based
.i21_0f_has_drive:
	dec	al			; 0-based
	mov	[cs:resolved_drive], al
	; Copy 8.3 name from FCB+1 to exec_fname
	push	si
	inc	si			; Skip drive byte
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, exec_fname
	pop	ds
	mov	cx, 11
.i21_0f_copy_name:
	lodsb
	mov	[cs:di], al
	inc	di
	dec	cx
	jnz	.i21_0f_copy_name
	pop	si			; SI = FCB start
	; Switch to shell seg
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Read root/current directory
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_0f_fail
	; Search for file
	mov	ax, SHELL_SEG
	mov	es, ax			; ES = SHELL_SEG for cmpsb
	push	si
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_0f_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_0f_not_found
	cmp	al, 0xE5
	je	.i21_0f_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_0f_found
.i21_0f_next:
	add	si, 32
	dec	cx
	jnz	.i21_0f_search
.i21_0f_not_found:
	pop	si
.i21_0f_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret
.i21_0f_found:
	; Fill FCB with file info
	; SI = dir entry, stack has original SI (FCB pointer)
	mov	ax, [si+28]		; File size low
	mov	dx, [si+30]		; File size high
	mov	bx, [si+26]		; Start cluster
	pop	si			; SI = caller's FCB (in caller's DS)
	pop	ds			; Restore caller's DS
	; FCB+0x0C: current block = 0
	mov	word [si+0x0C], 0
	; FCB+0x0E: record size = 128 (default)
	mov	word [si+0x0E], 128
	; FCB+0x10: file size (4 bytes)
	mov	[si+0x10], ax
	mov	[si+0x12], dx
	; FCB+0x1A: start cluster (undocumented but used)
	mov	[si+0x1A], bx
	; FCB+0x20: current record = 0
	mov	byte [si+0x20], 0
	; FCB+0x21: random record = 0
	mov	word [si+0x21], 0
	mov	word [si+0x23], 0
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al			; AL=0 success
	iret

; --- AH=10: Close file (FCB) ---
; Input: DS:DX = opened FCB
; Returns: AL=0 success
.i21_10:
	xor	al, al
	iret

; --- AH=11: Find first (FCB) ---
; Input: DS:DX = FCB with filename (may contain ? wildcards)
; Returns: AL=0 found (DTA filled with FCB-format result), AL=FF not found
.i21_11:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx
	; Get drive
	mov	al, [si]
	or	al, al
	jnz	.i21_11_has_drv
	mov	al, [cs:cur_drive]
	inc	al
.i21_11_has_drv:
	dec	al
	mov	[cs:resolved_drive], al
	; Copy search name from FCB+1 to wild_pattern
	inc	si
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, wild_pattern
	pop	ds
	mov	cx, 11
.i21_11_copy:
	lodsb
	mov	[cs:di], al
	inc	di
	dec	cx
	jnz	.i21_11_copy
	; Switch to shell
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_11_fail
	; Search
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	xor	bx, bx
.i21_11_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_11_fail
	cmp	al, 0xE5
	je	.i21_11_next
	test	byte [si+11], 0x08	; Skip volume labels
	jnz	.i21_11_next
	mov	di, wild_pattern
	call	match_wildcard
	jc	.i21_11_next
	; Found — save index for FindNext
	mov	[cs:.i21_11_idx], bx
	; Fill DTA with FCB-format result
	; DTA+0: drive, DTA+1-11: filename, DTA+12-31: dir entry data
	mov	es, [cs:dta_seg]
	mov	di, [cs:dta_off]
	mov	al, [cs:resolved_drive]
	inc	al			; 1-based
	mov	[es:di], al
	; Copy 8.3 name
	push	si
	push	cx
	inc	di
	mov	cx, 11
.i21_11_cpname:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_11_cpname
	pop	cx
	pop	si
	; Copy rest of dir entry (bytes 11-31 = 21 bytes)
	push	si
	add	si, 11
	mov	cx, 21
.i21_11_cprest:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_11_cprest
	pop	si
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al
	iret
.i21_11_next:
	add	si, 32
	inc	bx
	dec	cx
	jnz	.i21_11_search
.i21_11_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret
.i21_11_idx:	dw	0

; --- AH=12: Find next (FCB) ---
; Returns: AL=0 found (DTA filled), AL=FF no more
.i21_12:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	bx, [.i21_11_idx]
	inc	bx
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	push	bx
	call	read_resolved_dir
	pop	bx
	jc	.i21_12_fail
	; Skip to entry BX
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	cmp	bx, cx
	jae	.i21_12_fail
	mov	ax, bx
	push	bx
	mov	bx, 32
	mul	bx
	pop	bx
	add	si, ax
	sub	cx, bx
	or	cx, cx
	jz	.i21_12_fail
.i21_12_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_12_fail
	cmp	al, 0xE5
	je	.i21_12_next
	test	byte [si+11], 0x08
	jnz	.i21_12_next
	mov	di, wild_pattern
	call	match_wildcard
	jc	.i21_12_next
	; Found
	mov	[.i21_11_idx], bx
	mov	es, [dta_seg]
	mov	di, [dta_off]
	mov	al, [resolved_drive]
	inc	al
	mov	[es:di], al
	push	si
	push	cx
	inc	di
	mov	cx, 11
.i21_12_cpname:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_12_cpname
	pop	cx
	pop	si
	push	si
	add	si, 11
	mov	cx, 21
.i21_12_cprest:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_12_cprest
	pop	si
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al
	iret
.i21_12_next:
	add	si, 32
	inc	bx
	dec	cx
	jnz	.i21_12_search
.i21_12_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret

; --- AH=13: Delete file (FCB) ---
; Input: DS:DX = FCB
; Returns: AL=0 success, AL=FF not found
.i21_13:
	; Convert to handle-based delete
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx
	; Build ASCIIZ filename from FCB
	mov	al, [si]
	or	al, al
	jnz	.i21_13_has_drv
	mov	al, [cs:cur_drive]
	inc	al
.i21_13_has_drv:
	dec	al
	mov	[cs:resolved_drive], al
	; Copy name to exec_fname
	inc	si
	push	ds
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	di, exec_fname
	pop	ds
	mov	cx, 11
.i21_13_cp:
	lodsb
	mov	[cs:di], al
	inc	di
	dec	cx
	jnz	.i21_13_cp
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_13_fail
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_13_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_13_fail
	cmp	al, 0xE5
	je	.i21_13_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_13_found
.i21_13_next:
	add	si, 32
	dec	cx
	jnz	.i21_13_search
.i21_13_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret
.i21_13_found:
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	mov	byte [si], 0xE5
	call	write_resolved_dir
	jc	.i21_13_fail
	call	read_fat
	jc	.i21_13_fail
	mov	ax, [exec_cluster]
.i21_13_free:
	cmp	ax, 2
	jb	.i21_13_free_done
	cmp	ax, 0xFF8
	jae	.i21_13_free_done
	push	ax
	call	fat12_next_cluster
	mov	[exec_cluster], ax
	pop	ax
	mov	bx, 0
	call	fat12_write_cluster
	mov	ax, [exec_cluster]
	jmp	.i21_13_free
.i21_13_free_done:
	call	write_fat
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al
	iret

; --- AH=14: Sequential read (FCB) ---
; Input: DS:DX = opened FCB
; Returns: AL=0 success, AL=1 EOF, AL=2 DTA too small, AL=3 partial
.i21_14:
	; FCB sequential read
	; DS:DX = opened FCB, reads one record to DTA
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx			; SI = FCB in caller's DS

	; Calculate byte offset = ((current_block * 128) + current_record) * record_size
	mov	ax, [si+0x0C]		; Current block
	mov	cl, 7
	shl	ax, cl			; * 128
	xor	ch, ch
	mov	cl, [si+0x20]		; Current record
	add	ax, cx			; AX = sequential record number
	mov	bx, [si+0x0E]		; Record size
	mul	bx			; DX:AX = byte offset

	; Fall through to shared read logic
.i21_14_with_offset:
	; Entry: DX:AX = byte offset, SI = FCB pointer, caller DS/ES on stack
	; Check if offset >= file size → EOF
	cmp	dx, [si+0x12]		; Compare high word
	ja	.i21_14_eof
	jb	.i21_14_not_eof
	cmp	ax, [si+0x10]		; Compare low word
	jae	.i21_14_eof
.i21_14_not_eof:

	; Save record size and file offset for later
	mov	[cs:.i21_14_offset], ax
	mov	[cs:.i21_14_offset+2], dx
	mov	[cs:.i21_14_recsize], bx

	; Get drive from FCB (0=default, 1=A, 2=B)
	mov	al, [si]
	or	al, al
	jnz	.i21_14_has_drive
	mov	al, [cs:cur_drive]
	inc	al
.i21_14_has_drive:
	dec	al
	mov	[cs:resolved_drive], al

	; Get start cluster from FCB
	mov	bx, [si+0x1A]		; Start cluster
	mov	[cs:exec_cluster], bx

	; Save caller DS, FCB pointer
	mov	[cs:.i21_14_fcb_off], si
	mov	[cs:.i21_14_fcb_seg], ds

	; Switch to SHELL_SEG
	mov	ax, SHELL_SEG
	mov	ds, ax

	; Read FAT
	call	read_fat
	jc	.i21_14_eof_restore

	; Walk cluster chain to find the cluster containing our offset
	mov	ax, [.i21_14_offset]
	mov	dx, [.i21_14_offset+2]
	; Bytes per cluster = SECS_PER_CLUST * 512 = 1024
	; Divide DX:AX by 1024 to get cluster index
	mov	cx, 10
.i21_14_div_loop:
	shr	dx, 1
	rcr	ax, 1
	dec	cx
	jnz	.i21_14_div_loop
	; AX = cluster index from start, DX should be 0
	mov	cx, ax			; CX = clusters to skip
	mov	ax, [exec_cluster]	; AX = start cluster
	or	cx, cx
	jz	.i21_14_at_cluster
.i21_14_walk_chain:
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jae	.i21_14_eof_restore	; Past end of chain
	dec	cx
	jnz	.i21_14_walk_chain
.i21_14_at_cluster:
	; AX = cluster number containing our data
	; Calculate offset within cluster
	push	ax
	mov	ax, [.i21_14_offset]
	and	ax, 0x03FF		; Offset within 1024-byte cluster
	mov	[cs:.i21_14_clust_off], ax
	pop	ax

	; Read this cluster into batch_buffer (preserve dir_buffer)
	call	cluster_to_chs
	mov	dl, [cs:resolved_drive]
	mov	bx, batch_buffer
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	int	0x13
	jc	.i21_14_eof_restore

	; Copy record_size bytes from batch_buffer+clust_off to DTA
	mov	si, batch_buffer
	add	si, [.i21_14_clust_off]
	mov	di, [dta_off]
	mov	es, [dta_seg]
	mov	cx, [.i21_14_recsize]
	; Don't read past cluster boundary
	mov	ax, 1024
	sub	ax, [.i21_14_clust_off]	; Bytes left in cluster
	cmp	cx, ax
	jbe	.i21_14_copy_ok
	mov	cx, ax			; Clamp to cluster boundary
.i21_14_copy_ok:
	push	cx			; Save actual bytes copied
	rep	movsb
	pop	cx

	; Advance record pointer in FCB
	mov	ds, [cs:.i21_14_fcb_seg]
	mov	si, [cs:.i21_14_fcb_off]
	mov	al, [si+0x20]		; Current record
	inc	al
	cmp	al, 128
	jb	.i21_14_no_block_inc
	xor	al, al
	inc	word [si+0x0C]		; Next block
.i21_14_no_block_inc:
	mov	[si+0x20], al

	; Check if we read a partial record (past EOF)
	mov	ax, [cs:.i21_14_offset]
	add	ax, [cs:.i21_14_recsize]
	mov	dx, [cs:.i21_14_offset+2]
	adc	dx, 0
	cmp	dx, [si+0x12]
	ja	.i21_14_partial
	jb	.i21_14_full
	cmp	ax, [si+0x10]
	ja	.i21_14_partial
.i21_14_full:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al			; AL=0 success
	iret

.i21_14_partial:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 3			; AL=3 partial record
	iret

.i21_14_eof_restore:
.i21_14_eof:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 1			; AL=1 EOF
	iret

.i21_14_offset:		dd	0
.i21_14_recsize:	dw	0
.i21_14_fcb_off:	dw	0
.i21_14_fcb_seg:	dw	0
.i21_14_clust_off:	dw	0

; --- AH=15: Sequential write (FCB) ---
; Input: DS:DX = opened FCB
; Returns: AL=0 success, AL=1 disk full, AL=2 DTA too small
.i21_15:
	; FCB sequential write
	; DS:DX = opened FCB, writes one record from DTA
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx			; SI = FCB in caller's DS

	; Calculate byte offset = ((current_block * 128) + current_record) * record_size
	mov	ax, [si+0x0C]		; Current block
	mov	cl, 7
	shl	ax, cl			; * 128
	xor	ch, ch
	mov	cl, [si+0x20]		; Current record
	add	ax, cx			; AX = sequential record number
	mov	bx, [si+0x0E]		; Record size
	mul	bx			; DX:AX = byte offset

	; Fall through to shared write logic
.i21_15_with_offset:
	; Entry: DX:AX = byte offset, SI = FCB pointer, caller DS/ES on stack
	; Save record size and file offset
	mov	[cs:.i21_15_offset], ax
	mov	[cs:.i21_15_offset+2], dx
	mov	[cs:.i21_15_recsize], bx

	; Get drive from FCB
	mov	al, [si]
	or	al, al
	jnz	.i21_15_has_drive
	mov	al, [cs:cur_drive]
	inc	al
.i21_15_has_drive:
	dec	al
	mov	[cs:resolved_drive], al

	; Copy 8.3 name from FCB+1 to exec_fname (for dir search)
	push	si
	push	cx
	inc	si			; Skip drive byte
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, exec_fname
	mov	cx, 11
.i21_15_copy_name:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_15_copy_name
	pop	cx
	pop	si

	; Get start cluster from FCB
	mov	bx, [si+0x1A]		; Start cluster
	mov	[cs:exec_cluster], bx

	; Save caller DS, FCB pointer
	mov	[cs:.i21_15_fcb_off], si
	mov	[cs:.i21_15_fcb_seg], ds

	; Switch to SHELL_SEG
	mov	ax, SHELL_SEG
	mov	ds, ax

	; Read FAT
	call	read_fat
	jc	.i21_15_err

	; If start cluster is 0, file is empty — need to allocate first cluster
	mov	ax, [exec_cluster]
	or	ax, ax
	jnz	.i21_15_have_start
	; Allocate first cluster
	call	.i21_15_alloc_cluster
	jc	.i21_15_err
	mov	[exec_cluster], ax
	; Update FCB start cluster
	push	ds
	mov	ds, [cs:.i21_15_fcb_seg]
	mov	si, [cs:.i21_15_fcb_off]
	mov	[si+0x1A], ax
	pop	ds
	; Mark as EOF
	push	bx
	mov	bx, 0xFFF
	call	fat12_write_cluster
	call	write_fat
	pop	bx
	; Update directory entry with new start cluster
	; The entry currently has cluster 0 — find it by matching name
	push	ax
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_15_skip_dir_alloc
	; Search by name (exec_fname was copied at entry)
	mov	di, dir_buffer
	mov	cx, [resolved_dir_entries]
	mov	ax, SHELL_SEG
	mov	es, ax			; Ensure ES = DS = SHELL_SEG for cmpsb
.i21_15_find_entry:
	cmp	byte [di], 0
	je	.i21_15_skip_dir_alloc
	cmp	byte [di], 0xE5
	je	.i21_15_find_next
	; Compare 11-byte name
	push	cx
	push	si
	push	di
	mov	si, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	di
	pop	si
	pop	cx
	je	.i21_15_entry_found
.i21_15_find_next:
	add	di, 32
	dec	cx
	jnz	.i21_15_find_entry
	jmp	.i21_15_skip_dir_alloc
.i21_15_entry_found:
	mov	ax, [exec_cluster]
	mov	[di+26], ax		; Set start cluster in dir entry
	call	write_resolved_dir
.i21_15_skip_dir_alloc:
	pop	ax
.i21_15_have_start:

	; Walk cluster chain to find the cluster containing our offset
	mov	ax, [.i21_15_offset]
	mov	dx, [.i21_15_offset+2]
	; Divide DX:AX by 1024 to get cluster index
	mov	cx, 10
.i21_15_div_loop:
	shr	dx, 1
	rcr	ax, 1
	dec	cx
	jnz	.i21_15_div_loop
	; AX = cluster index from start
	mov	cx, ax			; CX = clusters to skip
	mov	ax, [exec_cluster]	; AX = start cluster
	or	cx, cx
	jz	.i21_15_at_cluster
.i21_15_walk_chain:
	push	cx
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jae	.i21_15_extend
	pop	cx
	dec	cx
	jnz	.i21_15_walk_chain
	jmp	.i21_15_at_cluster

.i21_15_extend:
	; Need to allocate a new cluster and link it
	pop	cx			; Remaining clusters to walk
	push	ax			; Save current (EOF) cluster
	; Actually, the current AX is >= 0xFF8 meaning we fell off the chain.
	; We need to go back and get the LAST valid cluster.
	; Let's re-walk to find the last cluster
	mov	ax, [exec_cluster]
.i21_15_find_last:
	mov	[cs:.i21_15_last_cl], ax
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.i21_15_find_last
	; .i21_15_last_cl = last cluster in chain
	pop	ax			; Discard
	; Allocate new cluster
	call	.i21_15_alloc_cluster
	jc	.i21_15_err
	; Link last → new
	push	ax			; Save new cluster
	push	bx
	mov	bx, ax			; BX = new cluster
	mov	ax, [cs:.i21_15_last_cl]
	call	fat12_write_cluster	; last → new
	pop	bx
	pop	ax
	push	ax
	push	bx
	mov	bx, 0xFFF
	call	fat12_write_cluster	; new → EOF
	call	write_fat
	pop	bx
	pop	ax
	; Continue walking if needed
	dec	cx
	jnz	.i21_15_walk_chain

.i21_15_at_cluster:
	; AX = cluster number to write into
	mov	[cs:.i21_15_cur_cl], ax

	; Calculate offset within cluster
	push	ax
	mov	ax, [.i21_15_offset]
	and	ax, 0x03FF		; Offset within 1024-byte cluster
	mov	[cs:.i21_15_clust_off], ax
	pop	ax

	; Read existing cluster data into batch_buffer (preserve dir_buffer)
	call	cluster_to_chs
	mov	dl, [cs:resolved_drive]
	mov	bx, batch_buffer
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	ah, 0x02
	mov	al, SECS_PER_CLUST
	int	0x13
	jc	.i21_15_err

	; Copy record_size bytes from DTA to batch_buffer+clust_off
	mov	di, batch_buffer
	add	di, [.i21_15_clust_off]
	mov	si, [cs:dta_off]
	push	ds
	mov	ds, [cs:dta_seg]
	mov	cx, [cs:.i21_15_recsize]
	; Don't write past cluster boundary
	mov	ax, 1024
	sub	ax, [cs:.i21_15_clust_off]
	cmp	cx, ax
	jbe	.i21_15_copy_ok
	mov	cx, ax
.i21_15_copy_ok:
	rep	movsb
	pop	ds

	; Write cluster back to disk
	mov	ax, [cs:.i21_15_cur_cl]
	call	cluster_to_chs
	mov	dl, [cs:resolved_drive]
	mov	bx, batch_buffer
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	ah, 0x03
	mov	al, SECS_PER_CLUST
	int	0x13
	jc	.i21_15_err

	; Advance record pointer in FCB
	mov	ds, [cs:.i21_15_fcb_seg]
	mov	si, [cs:.i21_15_fcb_off]
	mov	al, [si+0x20]		; Current record
	inc	al
	cmp	al, 128
	jb	.i21_15_no_block_inc
	xor	al, al
	inc	word [si+0x0C]		; Next block
.i21_15_no_block_inc:
	mov	[si+0x20], al

	; Update file size in FCB if we wrote past current end
	mov	ax, [cs:.i21_15_offset]
	add	ax, [cs:.i21_15_recsize]
	mov	dx, [cs:.i21_15_offset+2]
	adc	dx, 0
	cmp	dx, [si+0x12]
	ja	.i21_15_update_size
	jb	.i21_15_size_ok
	cmp	ax, [si+0x10]
	jbe	.i21_15_size_ok
.i21_15_update_size:
	mov	[si+0x10], ax
	mov	[si+0x12], dx
.i21_15_size_ok:

	; Update directory entry with new file size (search by name)
	push	ax
	push	dx
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax			; ES = SHELL_SEG for cmpsb
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_15_skip_dir
	mov	di, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_15_dir_search:
	cmp	byte [di], 0
	je	.i21_15_skip_dir
	cmp	byte [di], 0xE5
	je	.i21_15_dir_next
	push	cx
	push	si
	push	di
	mov	si, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	di
	pop	si
	pop	cx
	je	.i21_15_dir_found
.i21_15_dir_next:
	add	di, 32
	dec	cx
	jnz	.i21_15_dir_search
	jmp	.i21_15_skip_dir
.i21_15_dir_found:
	; Update start cluster and size from FCB
	mov	ax, [cs:exec_cluster]
	mov	[di+26], ax		; Ensure start cluster is set
	push	ds
	mov	ds, [cs:.i21_15_fcb_seg]
	mov	si, [cs:.i21_15_fcb_off]
	mov	ax, [si+0x10]
	mov	[cs:di+28], ax		; Update size low
	mov	ax, [si+0x12]
	mov	[cs:di+30], ax		; Update size high
	pop	ds
	call	write_resolved_dir
.i21_15_skip_dir:
	pop	dx
	pop	ax

	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al			; AL=0 success
	iret

.i21_15_err:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 1			; AL=1 disk full / error
	iret

; Helper: find a free cluster
; Returns: AX = free cluster number, CF=0 / CF=1 if disk full
.i21_15_alloc_cluster:
	push	cx
	mov	ax, 2
.i21_15_find_free:
	cmp	ax, 720
	jae	.i21_15_no_free
	push	ax
	call	fat12_read_cluster
	cmp	ax, 0
	pop	ax
	je	.i21_15_found_free
	inc	ax
	jmp	.i21_15_find_free
.i21_15_found_free:
	pop	cx
	clc
	ret
.i21_15_no_free:
	pop	cx
	stc
	ret

.i21_15_offset:		dd	0
.i21_15_recsize:	dw	0
.i21_15_fcb_off:	dw	0
.i21_15_fcb_seg:	dw	0
.i21_15_clust_off:	dw	0
.i21_15_cur_cl:		dw	0
.i21_15_last_cl:	dw	0

; --- AH=16: Create file (FCB) ---
; Input: DS:DX = FCB
; Returns: AL=0 success, AL=FF error
.i21_16:
	; FCB create file — create/truncate file, fill FCB
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx
	; Get drive
	mov	al, [si]
	or	al, al
	jnz	.i21_16_has_drv
	mov	al, [cs:cur_drive]
	inc	al
.i21_16_has_drv:
	dec	al
	mov	[cs:resolved_drive], al
	; Copy 8.3 name from FCB+1 to exec_fname
	push	si
	inc	si
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, exec_fname
	mov	cx, 11
.i21_16_copy:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_16_copy
	pop	si			; SI = FCB
	; Switch to SHELL_SEG
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Read current directory
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_16_fail
	; Search for existing file or free slot
	mov	di, dir_buffer
	mov	cx, [resolved_dir_entries]
	mov	word [cs:.i21_16_free], 0	; No free slot found yet
.i21_16_search:
	mov	al, [di]
	cmp	al, 0
	je	.i21_16_save_free
	cmp	al, 0xE5
	je	.i21_16_save_free
	; Compare names
	push	cx
	push	si
	push	di
	mov	si, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	di
	pop	si
	pop	cx
	je	.i21_16_found_existing
.i21_16_next:
	add	di, 32
	dec	cx
	jnz	.i21_16_search
	; Not found — use free slot
	mov	di, [cs:.i21_16_free]
	or	di, di
	jz	.i21_16_fail		; No free slots
	jmp	.i21_16_create_new
.i21_16_save_free:
	cmp	word [cs:.i21_16_free], 0
	jnz	.i21_16_next
	mov	[cs:.i21_16_free], di
	cmp	al, 0			; End of directory?
	je	.i21_16_create_at_free
	jmp	.i21_16_next
.i21_16_create_at_free:
	mov	di, [cs:.i21_16_free]

.i21_16_create_new:
	; DI = free directory entry. Fill it.
	push	di
	mov	si, exec_fname
	mov	cx, 11
	rep	movsb			; Copy filename
	pop	di
	; Clear rest of entry
	mov	byte [di+11], 0x20	; Archive attribute
	mov	word [di+12], 0
	mov	word [di+14], 0
	mov	word [di+16], 0
	mov	word [di+18], 0
	mov	word [di+20], 0
	mov	word [di+22], 0
	mov	word [di+24], 0
	mov	word [di+26], 0		; Start cluster = 0 (empty)
	mov	word [di+28], 0		; File size = 0
	mov	word [di+30], 0
	; Write directory back
	call	write_resolved_dir
	jc	.i21_16_fail
	jmp	.i21_16_fill_fcb

.i21_16_found_existing:
	; Truncate: set size to 0, free cluster chain
	; Free old clusters if any
	mov	ax, [di+26]
	or	ax, ax
	jz	.i21_16_trunc_done
	; Free cluster chain
	push	di
	call	read_fat
	pop	di
	jc	.i21_16_trunc_done
	mov	ax, [di+26]
.i21_16_free_chain:
	cmp	ax, 0xFF8
	jae	.i21_16_chain_freed
	push	ax
	call	fat12_next_cluster
	push	ax			; Save next
	pop	bx			; BX = next
	pop	ax			; AX = current
	push	bx
	mov	bx, 0
	call	fat12_write_cluster	; Mark current as free
	pop	ax			; AX = next
	jmp	.i21_16_free_chain
.i21_16_chain_freed:
	call	write_fat
.i21_16_trunc_done:
	mov	word [di+26], 0		; Clear start cluster
	mov	word [di+28], 0		; Size = 0
	mov	word [di+30], 0
	call	write_resolved_dir

.i21_16_fill_fcb:
	; Fill caller's FCB
	pop	ds			; Restore caller DS
	mov	si, dx			; SI = caller's FCB
	mov	word [si+0x0C], 0	; Current block = 0
	mov	word [si+0x0E], 128	; Record size = 128
	mov	word [si+0x10], 0	; File size = 0
	mov	word [si+0x12], 0
	mov	word [si+0x1A], 0	; Start cluster = 0
	mov	byte [si+0x20], 0	; Current record = 0
	mov	word [si+0x21], 0	; Random record = 0
	mov	word [si+0x23], 0
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al			; AL=0 success
	iret

.i21_16_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret

.i21_16_free:	dw	0

; --- AH=21: Random read (FCB) ---
; Input: DS:DX = opened FCB
; Returns: AL=0 success, AL=1 EOF, AL=2 DTA too small, AL=3 partial
; Uses random record field (FCB+21h) instead of sequential block/record
.i21_21:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx

	; Calculate byte offset = random_record * record_size
	mov	ax, [si+0x21]		; Random record (low word)
	mov	bx, [si+0x0E]		; Record size
	mul	bx			; DX:AX = byte offset

	; Update current block/record from random record
	; (preserve DX:AX = offset and BX = record_size)
	push	ax
	push	dx
	push	bx
	mov	ax, [si+0x21]		; Random record
	xor	dx, dx
	mov	bx, 128
	div	bx			; AX = block, DX = record within block
	mov	[si+0x0C], ax		; Current block
	mov	[si+0x20], dl		; Current record
	pop	bx
	pop	dx
	pop	ax

	; Now do the same read as AH=14 with this offset
	jmp	.i21_14_with_offset

; --- AH=22: Random write (FCB) ---
; Input: DS:DX = opened FCB
; Returns: AL=0 success, AL=1 disk full, AL=2 DTA too small
.i21_22:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx

	; Calculate byte offset = random_record * record_size
	mov	ax, [si+0x21]		; Random record (low word)
	mov	bx, [si+0x0E]		; Record size
	mul	bx			; DX:AX = byte offset

	; Update current block/record from random record
	; (preserve DX:AX = offset and BX = record_size)
	push	ax
	push	dx
	push	bx
	mov	ax, [si+0x21]
	xor	dx, dx
	mov	bx, 128
	div	bx
	mov	[si+0x0C], ax		; Current block
	mov	[si+0x20], dl		; Current record
	pop	bx
	pop	dx
	pop	ax

	; Now do the same write as AH=15 with this offset
	jmp	.i21_15_with_offset

; --- AH=00: Terminate program ---
; Same as INT 20h
.i21_00:
	mov	ah, 0x4C
	xor	al, al
	jmp	.i21_4c

; --- AH=03: Auxiliary input ---
; Returns: AL = character from AUX device
.i21_03:
	xor	al, al			; Return null
	iret

; --- AH=04: Auxiliary output ---
; Input: DL = character to output to AUX
.i21_04:
	iret				; Ignore

; --- AH=05: Printer output ---
; Input: DL = character to print
.i21_05:
	iret				; Ignore

; --- AH=1B: Get allocation info for default drive ---
; Returns: AL=sectors/cluster, CX=bytes/sector, DX=total clusters, DS:BX=media byte
.i21_1b:
	push	cs
	pop	ds
	mov	bx, .i21_1b_media
	mov	al, SECS_PER_CLUST
	mov	cx, 512
	mov	dx, (TOTAL_SECS - DATA_START_SEC) / SECS_PER_CLUST
	iret
.i21_1b_media:	db	MEDIA_BYTE

; --- AH=1C: Get allocation info for specific drive ---
; Input: DL = drive (0=default, 1=A, 2=B)
; Returns: same as AH=1B
.i21_1c:
	jmp	.i21_1b			; Same drive, same geometry

; --- AH=23: Get file size (FCB) ---
; Input: DS:DX = unopened FCB
; Output: AL=0 found (random record = file size / record size), AL=FF not found
.i21_23:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx
	; Open via FCB to get file size
	mov	al, [si]
	or	al, al
	jnz	.i21_23_has_drv
	mov	al, [cs:cur_drive]
	inc	al
.i21_23_has_drv:
	dec	al
	mov	[cs:resolved_drive], al
	; Copy 8.3 name
	push	si
	inc	si
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, exec_fname
	mov	cx, 11
.i21_23_copy:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_23_copy
	pop	si
	; Search directory
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_23_fail
	push	si
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_23_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_23_nf
	cmp	al, 0xE5
	je	.i21_23_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_23_found
.i21_23_next:
	add	si, 32
	dec	cx
	jnz	.i21_23_search
.i21_23_nf:
	pop	si
.i21_23_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret
.i21_23_found:
	; SI = dir entry, file size at [SI+28..31]
	mov	ax, [si+28]		; Size low
	mov	dx, [si+30]		; Size high
	pop	si			; SI = caller's FCB
	pop	ds			; Restore caller DS
	; Record size is at FCB+0x0E
	mov	cx, [si+0x0E]
	or	cx, cx
	jz	.i21_23_done_zero
	; Random record = ceil(file_size / record_size)
	; DX:AX / CX
	div	cx			; AX = quotient, DX = remainder
	or	dx, dx
	jz	.i21_23_no_round
	inc	ax			; Round up
.i21_23_no_round:
	; Store in FCB random record field (3 bytes at +0x21)
	mov	[si+0x21], ax
	mov	byte [si+0x23], 0
.i21_23_done_zero:
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al
	iret

; --- AH=24: Set random record field (FCB) ---
; Input: DS:DX = opened FCB
; Sets FCB random record = (current_block * 128) + current_record
.i21_24:
	push	si
	push	cx
	mov	si, dx
	mov	ax, [si+0x0C]		; Current block
	mov	cl, 7
	shl	ax, cl			; * 128
	xor	ch, ch
	mov	cl, [si+0x20]		; Current record
	add	ax, cx
	mov	[si+0x21], ax		; Random record low word
	mov	word [si+0x23], 0	; Random record high byte (always 0 for small files)
	pop	cx
	pop	si
	iret

; --- AH=34: Get InDOS flag address ---
; Returns: ES:BX = pointer to InDOS flag byte
.i21_34:
	mov	bx, SHELL_SEG
	mov	es, bx
	mov	bx, .i21_34_indos
	iret
.i21_34_indos:	db	0

; --- AH=17: Rename file (FCB) ---
; Input: DS:DX = modified FCB (old name at +1, new name at +17)
; Returns: AL=0 success, AL=FF not found
.i21_17:
	push	bx
	push	cx
	push	si
	push	di
	push	es
	push	ds
	mov	si, dx
	; Get drive
	mov	al, [si]
	or	al, al
	jnz	.i21_17_has_drv
	mov	al, [cs:cur_drive]
	inc	al
.i21_17_has_drv:
	dec	al
	mov	[cs:resolved_drive], al
	; Copy old name from FCB+1 to exec_fname
	push	si
	inc	si
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, exec_fname
	mov	cx, 11
.i21_17_copy_old:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_17_copy_old
	pop	si
	; Copy new name from FCB+17 to wild_pattern (temp)
	push	si
	add	si, 17
	mov	di, wild_pattern
	mov	cx, 11
.i21_17_copy_new:
	lodsb
	mov	[es:di], al
	inc	di
	dec	cx
	jnz	.i21_17_copy_new
	pop	si
	; Switch to SHELL_SEG
	mov	ax, SHELL_SEG
	mov	ds, ax
	; Read directory
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jc	.i21_17_fail
	; Search for old name
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_17_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_17_fail
	cmp	al, 0xE5
	je	.i21_17_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_17_found
.i21_17_next:
	add	si, 32
	dec	cx
	jnz	.i21_17_search
	jmp	.i21_17_fail
.i21_17_found:
	; Copy new name over old
	mov	di, si			; DI = dir entry
	mov	si, wild_pattern
	mov	cx, 11
	rep	movsb
	call	write_resolved_dir
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	xor	al, al
	iret
.i21_17_fail:
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	cx
	pop	bx
	mov	al, 0xFF
	iret

; --- AH=27: Random block read (FCB) ---
; Input: DS:DX = opened FCB, CX = number of records
; Returns: AL=0 all read, AL=1 EOF, AL=3 partial, CX = records actually read
.i21_27:
	; FCB block read: read CX records starting at random record
	; Set block/record from random record, then loop AH=14 via INT 21h
	mov	[cs:.i21_27_count], cx
	mov	word [cs:.i21_27_done], 0
	mov	[cs:.i21_27_fcb_off], dx	; Save FCB offset
	; Save DTA
	mov	ax, [cs:dta_off]
	mov	[cs:.i21_27_dta_off], ax
	mov	ax, [cs:dta_seg]
	mov	[cs:.i21_27_dta_seg], ax
	; Save SI = FCB pointer
	push	si
	mov	si, dx
.i21_27_loop:
	mov	cx, [cs:.i21_27_count]
	cmp	word [cs:.i21_27_done], cx
	jae	.i21_27_ok
	; Set block/record from random record
	push	bx
	push	dx
	mov	ax, [si+0x21]
	xor	dx, dx
	mov	bx, 128
	div	bx
	mov	[si+0x0C], ax		; Block
	mov	[si+0x20], dl		; Record
	pop	dx
	pop	bx
	; Call AH=14 (sequential read) — DX must point to FCB
	mov	dx, [cs:.i21_27_fcb_off]
	mov	ah, 0x14
	int	0x21
	cmp	al, 1
	je	.i21_27_eof
	; Advance DTA by record size
	push	bx
	mov	bx, [si+0x0E]
	add	[cs:dta_off], bx
	pop	bx
	; Advance random record
	inc	word [si+0x21]
	inc	word [cs:.i21_27_done]
	jmp	.i21_27_loop
.i21_27_ok:
	mov	al, 0
	jmp	.i21_27_ret
.i21_27_eof:
	mov	al, 1
.i21_27_ret:
	; Restore DTA
	push	ax
	mov	ax, [cs:.i21_27_dta_off]
	mov	[cs:dta_off], ax
	mov	ax, [cs:.i21_27_dta_seg]
	mov	[cs:dta_seg], ax
	pop	ax
	mov	cx, [cs:.i21_27_done]
	pop	si
	iret
.i21_27_count:	dw	0
.i21_27_done:	dw	0
.i21_27_dta_off: dw	0
.i21_27_dta_seg: dw	0
.i21_27_fcb_off: dw	0

; --- AH=28: Random block write (FCB) ---
; Input: DS:DX = opened FCB, CX = number of records (0 = set file size)
; Returns: AL=0 success, AL=1 disk full, CX = records actually written
.i21_28:
	; CX=0 means set file size to random_record * record_size
	push	si
	mov	si, dx
	or	cx, cx
	jnz	.i21_28_write
	; Set file size only (truncate)
	mov	ax, [si+0x21]		; Random record
	mov	bx, [si+0x0E]		; Record size
	mul	bx			; DX:AX = new file size
	mov	[si+0x10], ax
	mov	[si+0x12], dx
	xor	cx, cx
	xor	al, al
	pop	si
	iret
.i21_28_write:
	mov	[cs:.i21_28_count], cx
	mov	word [cs:.i21_28_done], 0
	mov	[cs:.i21_28_fcb_off], dx
	mov	ax, [cs:dta_off]
	mov	[cs:.i21_28_dta_off], ax
	mov	ax, [cs:dta_seg]
	mov	[cs:.i21_28_dta_seg], ax
.i21_28_loop:
	mov	cx, [cs:.i21_28_count]
	cmp	word [cs:.i21_28_done], cx
	jae	.i21_28_ok
	; Set block/record from random record
	push	bx
	push	dx
	mov	ax, [si+0x21]
	xor	dx, dx
	mov	bx, 128
	div	bx
	mov	[si+0x0C], ax
	mov	[si+0x20], dl
	pop	dx
	pop	bx
	; Call AH=15 (sequential write) — DX must point to FCB
	mov	dx, [cs:.i21_28_fcb_off]
	mov	ah, 0x15
	int	0x21
	cmp	al, 0
	jne	.i21_28_full
	; Advance DTA
	push	bx
	mov	bx, [si+0x0E]
	add	[cs:dta_off], bx
	pop	bx
	; Advance random record
	inc	word [si+0x21]
	inc	word [cs:.i21_28_done]
	jmp	.i21_28_loop
.i21_28_ok:
	mov	al, 0
	jmp	.i21_28_ret
.i21_28_full:
	mov	al, 1
.i21_28_ret:
	push	ax
	mov	ax, [cs:.i21_28_dta_off]
	mov	[cs:dta_off], ax
	mov	ax, [cs:.i21_28_dta_seg]
	mov	[cs:dta_seg], ax
	pop	ax
	mov	cx, [cs:.i21_28_done]
	pop	si
	iret
.i21_28_count:	dw	0
.i21_28_done:	dw	0
.i21_28_dta_off: dw	0
.i21_28_dta_seg: dw	0
.i21_28_fcb_off: dw	0

; --- AH=50: Set current PSP ---
; Input: BX = new PSP segment
.i21_50:
	mov	[cs:exec_seg], bx
	iret

; --- AH=51: Get current PSP ---
; Output: BX = current PSP segment (same as AH=62)
.i21_51:
	mov	bx, [cs:exec_seg]
	iret

; --- AH=5B: Create new file (fail if exists) ---
; Input: CX = attributes, DS:DX = ASCIIZ filename
; Output: AX = handle, CF=0 / CF=1 AX=error (80 = file exists)
.i21_5b:
	; First check if file exists using AH=4E (FindFirst)
	push	cx
	push	dx
	push	ds
	mov	ah, 0x4E
	mov	cx, 0x27		; All attributes
	int	0x21
	pop	ds
	pop	dx
	pop	cx
	jc	.i21_5b_create		; Not found — good, create it
	; File exists — return error
	mov	ax, 80			; File exists
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret
.i21_5b_create:
	; File doesn't exist — use AH=3C to create
	mov	ah, 0x3C
	int	0x21
	iret				; CF and AX already set by AH=3C

; --- AH=1F: Get default DPB ---
; Returns: AL=0, DS:BX = pointer to DPB
.i21_1f:
	push	cs
	pop	ds
	mov	bx, .dpb_data
	xor	al, al
	iret

; --- AH=32: Get DPB for specific drive ---
; Input: DL = drive (0=default, 1=A, 2=B)
; Returns: AL=0, DS:BX = pointer to DPB / AL=FF invalid drive
.i21_32:
	cmp	dl, 2			; Only drives 0-1 (A)
	ja	.i21_32_bad
	push	cs
	pop	ds
	mov	bx, .dpb_data
	xor	al, al
	iret
.i21_32_bad:
	mov	al, 0xFF
	iret

; Drive Parameter Block for 360K floppy
.dpb_data:
	db	0			; +00: drive number (0=A)
	db	0			; +01: unit number
	dw	512			; +02: bytes per sector
	db	1			; +04: sectors/cluster - 1
	db	1			; +05: cluster shift (log2 of secs/cluster)
	dw	1			; +06: first FAT sector
	db	2			; +08: number of FATs
	dw	112			; +09: root dir entries
	dw	DATA_START_SEC		; +0B: first data sector
	dw	(TOTAL_SECS - DATA_START_SEC) / SECS_PER_CLUST + 1  ; +0D: max cluster + 1
	db	2			; +0F: sectors per FAT
	dw	ROOT_DIR_SEC		; +10: first root dir sector
	dd	0			; +12: device driver header (N/A)
	db	MEDIA_BYTE		; +16: media descriptor
	db	0			; +17: access flag (0=disk accessed)
	dd	0			; +18: next DPB pointer (0=last)
	dw	0			; +1C: last cluster allocated
	dw	0			; +1E: free clusters (0xFFFF=unknown)

; --- AH=2B: Set date ---
; Input: CX=year, DH=month, DL=day
; Returns: AL=0 success, AL=FF invalid
.i21_2b:
	; Validate basic ranges
	cmp	cx, 1980
	jb	.i21_2b_fail
	cmp	dh, 0
	je	.i21_2b_fail
	cmp	dh, 12
	ja	.i21_2b_fail
	cmp	dl, 0
	je	.i21_2b_fail
	cmp	dl, 31
	ja	.i21_2b_fail
	; Set RTC date via INT 1Ah AH=05
	push	ax
	push	cx
	push	dx
	; Convert year to BCD century + year
	mov	ax, cx
	xor	dx, dx
	mov	cx, 100
	div	cx		; AX=century, DX=year
	push	dx
	call	.bin_to_bcd
	mov	ch, al		; Century BCD
	pop	ax
	call	.bin_to_bcd
	mov	cl, al		; Year BCD
	pop	dx
	push	dx
	mov	al, dh
	call	.bin_to_bcd
	mov	dh, al		; Month BCD
	pop	dx
	push	dx
	mov	al, dl
	call	.bin_to_bcd
	mov	dl, al		; Day BCD
	mov	ah, 0x05
	int	0x1A
	pop	dx
	pop	cx
	pop	ax
	xor	al, al
	iret
.i21_2b_fail:
	mov	al, 0xFF
	iret

; --- AH=2D: Set time ---
; Input: CH=hour, CL=minute, DH=second, DL=hundredths
; Returns: AL=0 success, AL=FF invalid
.i21_2d:
	cmp	ch, 23
	ja	.i21_2d_fail
	cmp	cl, 59
	ja	.i21_2d_fail
	cmp	dh, 59
	ja	.i21_2d_fail
	; Set RTC time via INT 1Ah AH=03
	push	ax
	push	cx
	push	dx
	mov	al, ch
	call	.bin_to_bcd
	mov	ch, al
	pop	dx
	pop	cx
	push	cx
	push	dx
	mov	al, cl
	call	.bin_to_bcd
	mov	cl, al
	pop	dx
	push	dx
	mov	al, dh
	call	.bin_to_bcd
	mov	dh, al
	xor	dl, dl		; DST flag = 0
	mov	ah, 0x03
	int	0x1A
	pop	dx
	pop	cx
	pop	ax
	xor	al, al
	iret
.i21_2d_fail:
	mov	al, 0xFF
	iret

; Binary to BCD helper
.bin_to_bcd:
	push	cx
	xor	ah, ah
	mov	cl, 10
	div	cl		; AL=tens, AH=ones
	mov	cl, 4
	shl	al, cl
	or	al, ah
	xor	ah, ah
	pop	cx
	ret

; --- AH=26: Create new PSP ---
; Input: DX = segment for new PSP
; Copies current PSP to new location (simplified)
.i21_26:
	push	si
	push	di
	push	cx
	push	es
	push	ds
	; Source = current PSP (exec_seg), dest = DX
	mov	es, dx
	mov	ax, [cs:exec_seg]
	or	ax, ax
	jnz	.i21_26_copy
	mov	ax, cs			; Fall back to shell seg
.i21_26_copy:
	mov	ds, ax
	xor	si, si
	xor	di, di
	mov	cx, 128
	rep	movsw
	pop	ds
	pop	es
	pop	cx
	pop	di
	pop	si
	iret

; --- AH=33: Get/set break flag ---
; AL=0: get → DL=flag, AL=1: set DL=flag
.i21_33:
	cmp	al, 0
	jne	.i21_33_set
	mov	dl, [cs:break_flag]
	iret
.i21_33_set:
	cmp	al, 1
	jne	.i21_33_other
	mov	[cs:break_flag], dl
	iret
.i21_33_other:
	; AL=5: get boot drive, AL=6: DOS version (misc)
	cmp	al, 5
	jne	.i21_33_done
	mov	dl, 1			; Boot drive = A: (1-based)
.i21_33_done:
	iret

; --- AH=38: Get country info ---
; Returns: BX=country code, DS:DX filled with info
; Simplified: return US defaults
.i21_38:
	cmp	al, 0
	jne	.i21_38_set
	mov	bx, 1			; Country code = USA
	; Fill buffer at DS:DX with US defaults
	push	di
	push	es
	mov	es, [cs:exec_seg]	; Caller's DS might differ
	; For safety, just clear CF and return
	pop	es
	pop	di
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_38_set:
	; Set country — ignore
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=54: Get verify flag ---
; Returns: AL = verify flag (0=off, 1=on)
.i21_54:
	mov	al, [cs:verify_flag]
	iret

; --- AH=58: Get/set allocation strategy ---
; AL=0: get → AX=strategy, AL=1: set BX=strategy
.i21_58:
	cmp	al, 0
	jne	.i21_58_set
	xor	ax, ax			; Strategy = first fit
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret
.i21_58_set:
	; Ignore, return success
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE
	pop	bp
	iret

; --- AH=59: Get extended error information ---
; Returns: AX=error code, BH=error class, BL=action, CH=locus
.i21_59:
	mov	ax, [cs:last_error]
	mov	bh, 1			; Class: out of resource
	mov	bl, 1			; Action: retry
	mov	ch, 1			; Locus: unknown
	iret

; --- AH=4B: EXEC — Load and execute program ---
; Input: AL=0 load+execute, AL=1 load overlay, AL=3 load overlay
;        DS:DX = ASCIIZ program name, ES:BX = parameter block
;        Parameter block: [+0] env seg, [+2] cmd tail ptr, [+4] FCB1, [+8] FCB2
; Returns: CF=0 success, CF=1 AX=error
.i21_4b:
	cmp	al, 0
	je	.i21_4b_exec
	; AL != 0: load overlay — not supported
	mov	ax, 1
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_4b_exec:
	; Save caller's ES:BX (parameter block pointer) to variables
	mov	[cs:.i21_4b_caller_es], es
	mov	[cs:.i21_4b_caller_bx], bx

	; Save parent SS:SP and exec_seg
	mov	[cs:exec_parent_ss], ss
	mov	[cs:exec_parent_sp], sp
	mov	ax, [cs:exec_seg]
	mov	[cs:.i21_4b_parent_seg], ax

	; Copy filename from caller's DS:DX to cmd_buffer
	; DS still = caller's DS, SI = DX = filename offset
	mov	si, dx
	push	ds			; Save caller DS again for copy
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	di, cmd_buffer
	mov	cx, 78
.i21_4b_copy_fname:
	lodsb				; Read from DS:SI (caller's memory)
	stosb				; Write to ES:DI (SHELL_SEG:cmd_buffer)
	or	al, al
	jz	.i21_4b_fname_done
	dec	cx
	jnz	.i21_4b_copy_fname
	mov	byte [es:di-1], 0
.i21_4b_fname_done:
	pop	ax			; Discard saved caller DS

	; Switch DS and ES to SHELL_SEG for all subsequent operations
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax

	; Parse filename
	mov	si, cmd_buffer
	mov	di, exec_fname
	call	parse_83_filename

	; If no extension, try .COM then .EXE
	cmp	byte [exec_fname+8], ' '
	jne	.i21_4b_has_ext
	mov	byte [exec_fname+8], 'C'
	mov	byte [exec_fname+9], 'O'
	mov	byte [exec_fname+10], 'M'
.i21_4b_has_ext:

	; Read current directory
	mov	al, [cur_drive]
	mov	[resolved_drive], al
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax
	call	read_resolved_dir
	jnc	.i21_4b_dir_ok
	mov	ax, 101
	jmp	.i21_4b_err_ax
.i21_4b_dir_ok:
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.i21_4b_search:
	mov	al, [si]
	cmp	al, 0
	je	.i21_4b_not_found
	cmp	al, 0xE5
	je	.i21_4b_search_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.i21_4b_found
.i21_4b_search_next:
	add	si, 32
	dec	cx
	jnz	.i21_4b_search

.i21_4b_not_found:
	; Try .EXE if we tried .COM
	cmp	byte [exec_fname+8], 'C'
	jne	.i21_4b_err
	mov	byte [exec_fname+8], 'E'
	mov	byte [exec_fname+9], 'X'
	mov	byte [exec_fname+10], 'E'
	call	read_resolved_dir
	jc	.i21_4b_err
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.i21_4b_search

.i21_4b_err:
	mov	ax, 2			; File not found
.i21_4b_err_ax:
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_4b_found:
	; Get file info
	mov	ax, [si+26]
	mov	[exec_cluster], ax
	mov	ax, [si+28]
	mov	[exec_size], ax
	mov	ax, [si+30]
	mov	[exec_size+2], ax

	; Load FAT
	call	read_fat
	jc	.i21_4b_err

	; Mark this as an EXEC-launched program
	inc	byte [exec_depth]

	; Save command tail from parameter block
	; Parameter block is at caller's ES:BX
	; [ES:BX+2] = far pointer to command tail
	push	ds
	mov	es, [cs:.i21_4b_caller_es]
	mov	bx, [cs:.i21_4b_caller_bx]
	mov	si, [es:bx+2]		; Command tail offset
	mov	ds, [es:bx+4]		; Command tail segment
	; Save command tail pointer for PSP setup
	mov	[cs:exec_cmdtail_ptr], si
	mov	[cs:.i21_4b_cmdtail_seg], ds
	pop	ds

	; Now reuse the existing exec machinery
	; Allocate memory
	mov	bx, 0xFFFF
	call	alloc_mem_core		; Probe: fails, BX = largest
	call	alloc_mem_core		; Allocate largest block
	jc	.i21_4b_no_mem

	mov	[exec_seg], ax

	; Build PSP (reuse existing PSP setup code inline)
	mov	es, ax

	; Clear PSP
	push	ax
	push	cx
	push	di
	xor	di, di
	xor	ax, ax
	mov	cx, 128
	rep	stosw
	pop	di
	pop	cx
	pop	ax

	; PSP:00 INT 20h
	mov	byte [es:0x00], 0xCD
	mov	byte [es:0x01], 0x20
	; PSP:02 Memory top
	push	es
	mov	ax, [exec_seg]
	dec	ax
	mov	es, ax
	mov	ax, [es:0x03]
	add	ax, [exec_seg]
	inc	ax
	pop	es
	mov	[es:0x02], ax
	; PSP:05 FAR CALL to DOS
	mov	byte [es:0x05], 0xCD
	mov	byte [es:0x06], 0x21
	mov	byte [es:0x07], 0xCB
	; PSP:0A-15 Save parent vectors
	push	ds
	xor	ax, ax
	mov	ds, ax
	mov	ax, [ds:0x88]
	mov	[es:0x0A], ax
	mov	ax, [ds:0x8A]
	mov	[es:0x0C], ax
	mov	ax, [ds:0x8C]
	mov	[es:0x0E], ax
	mov	ax, [ds:0x8E]
	mov	[es:0x10], ax
	mov	ax, [ds:0x90]
	mov	[es:0x12], ax
	mov	ax, [ds:0x92]
	mov	[es:0x14], ax
	pop	ds
	; PSP:16 Parent PSP
	mov	ax, [cs:.i21_4b_parent_seg]
	mov	[es:0x16], ax
	; PSP:18 JFT — inherit from parent
	push	di
	push	cx
	push	ds
	mov	di, 0x18
	mov	ds, [cs:.i21_4b_parent_seg]
	mov	si, 0x18
	mov	cx, MAX_HANDLES
	rep	movsb
	pop	ds
	; Increment refcounts for inherited FILE handles (5+)
	push	bx
	mov	bx, 5
.i21_4b_inherit_ref:
	cmp	bx, MAX_HANDLES
	jae	.i21_4b_inherit_done
	mov	al, [es:0x18 + bx]
	cmp	al, 0xFF
	je	.i21_4b_inherit_next
	xor	ah, ah
	push	bx
	mov	bx, ax
	inc	byte [cs:sft_refcount + bx]
	pop	bx
.i21_4b_inherit_next:
	inc	bx
	jmp	.i21_4b_inherit_ref
.i21_4b_inherit_done:
	pop	bx
	pop	cx
	pop	di
	; PSP:2C Environment
	; Use caller's environment or the parameter block env
	push	bx
	mov	es, [cs:.i21_4b_caller_es]
	mov	bx, [cs:.i21_4b_caller_bx]
	mov	ax, [es:bx]		; Env segment from param block
	or	ax, ax
	jnz	.i21_4b_has_env
	mov	ax, [env_seg]		; Use shell's env if 0
.i21_4b_has_env:
	mov	es, [exec_seg]
	mov	[es:0x2C], ax
	pop	bx
	; PSP:32/34 Handle table
	mov	word [es:0x32], MAX_HANDLES
	mov	word [es:0x34], 0x18
	mov	ax, [exec_seg]
	mov	word [es:0x36], ax
	; PSP:50 INT 21/RETF
	mov	byte [es:0x50], 0xCD
	mov	byte [es:0x51], 0x21
	mov	byte [es:0x52], 0xCB

	; PSP:80 Command tail from parameter block
	push	si
	push	di
	push	ds
	mov	ds, [cs:.i21_4b_cmdtail_seg]
	mov	si, [cs:exec_cmdtail_ptr]
	mov	di, 0x80
	; First byte is length
	mov	cl, [si]
	mov	[es:di], cl
	xor	ch, ch
	inc	si
	inc	di
	rep	movsb
	mov	byte [es:di], 0x0D
	pop	ds
	pop	di
	pop	si

	; Set DTA
	mov	ax, [exec_seg]
	mov	[dta_seg], ax
	mov	word [dta_off], 0x0080

	; Save BIOS vectors
	push	ds
	xor	ax, ax
	mov	ds, ax
	mov	ax, [ds:0x20]
	mov	[cs:saved_int08], ax
	mov	ax, [ds:0x22]
	mov	[cs:saved_int08+2], ax
	mov	ax, [ds:0x24]
	mov	[cs:saved_int09], ax
	mov	ax, [ds:0x26]
	mov	[cs:saved_int09+2], ax
	mov	ax, [ds:0x40]
	mov	[cs:saved_int10], ax
	mov	ax, [ds:0x42]
	mov	[cs:saved_int10+2], ax
	mov	ax, [ds:0x70]
	mov	[cs:saved_int1c], ax
	mov	ax, [ds:0x72]
	mov	[cs:saved_int1c+2], ax
	pop	ds

	; Load file
	mov	bx, 0x0100
	mov	ax, [exec_cluster]
	mov	es, [exec_seg]

.i21_4b_load:
	push	ax
	sub	ax, 2
	mov	cx, SECS_PER_CLUST
	push	cx
	mul	cx
	add	ax, DATA_START_SEC
	mov	[cs:exec_cur_sec], ax
	pop	cx
.i21_4b_load_sec:
	push	cx
	mov	ax, [cs:exec_cur_sec]
	xor	dx, dx
	push	bx
	mov	bx, 18
	div	bx
	mov	ch, al
	mov	ax, dx
	xor	dx, dx
	mov	bx, 9
	div	bx
	mov	dh, al
	mov	cl, dl
	inc	cl
	pop	bx
	push	es
	mov	ah, 0x02
	mov	al, 1
	mov	dl, [resolved_drive]
	int	0x13
	pop	es
	jc	.i21_4b_load_err
	mov	ax, es
	add	ax, 512 / 16
	mov	es, ax
	inc	word [cs:exec_cur_sec]
	pop	cx
	dec	cx
	jnz	.i21_4b_load_sec
	pop	ax
	call	fat12_next_cluster
	cmp	ax, 0xFF8
	jb	.i21_4b_load

	; Check for EXE
	mov	ax, [exec_seg]
	mov	es, ax
	cmp	word [es:0x100], 0x5A4D
	je	.i21_4b_exe

	; === .COM launch ===
	mov	word [exec_jmp_ip], 0x0100
	mov	ax, [exec_seg]
	mov	[exec_jmp_cs], ax
	; Set up program segments
	mov	ax, [exec_seg]
	mov	ds, ax
	mov	es, ax
	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti
	jmp	far [cs:exec_jmp_ip]

	; === .EXE launch ===
.i21_4b_exe:
	mov	ax, [exec_seg]
	mov	es, ax
	mov	ax, [es:0x108]		; Header paragraphs
	mov	[exe_hdr_size], ax
	mov	bx, [exec_seg]
	add	bx, 0x10
	add	bx, ax
	mov	[exe_load_seg], bx
	; CS:IP
	mov	ax, [es:0x116]
	add	ax, bx
	mov	[exec_jmp_cs], ax
	mov	ax, [es:0x114]
	mov	[exec_jmp_ip], ax
	; SS:SP
	mov	ax, [es:0x10E]
	add	ax, bx
	mov	dx, [es:0x110]
	; Relocations
	mov	cx, [es:0x106]
	jcxz	.i21_4b_no_reloc
	mov	di, [es:0x118]
	add	di, 0x100
.i21_4b_reloc:
	push	cx
	mov	si, [es:di]
	mov	cx, [es:di+2]
	add	cx, [exe_load_seg]
	push	es
	push	di
	mov	es, cx
	mov	di, si
	mov	cx, [es:di]
	add	cx, [cs:exe_load_seg]
	mov	[es:di], cx
	pop	di
	pop	es
	pop	cx
	add	di, 4
	dec	cx
	jnz	.i21_4b_reloc
.i21_4b_no_reloc:
	cli
	mov	ss, ax
	mov	sp, dx
	sti
	mov	ax, [exec_seg]
	mov	ds, ax
	mov	es, ax
	jmp	far [cs:exec_jmp_ip]

.i21_4b_no_mem:
	dec	byte [cs:exec_depth]
	mov	ax, 8
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret


.i21_4b_load_err:
	pop	cx
	pop	ax
	dec	byte [cs:exec_depth]
	mov	es, [cs:exec_seg]
	mov	ah, 0x49
	int	0x21
	mov	ax, 5
	push	bp
	mov	bp, sp
	or	word [bp+6], 0x0001
	pop	bp
	iret

.i21_4b_caller_ds:	dw	0
.i21_4b_caller_dx:	dw	0
.i21_4b_caller_es:	dw	0
.i21_4b_caller_bx:	dw	0
.i21_4b_parent_seg:	dw	0
.i21_4b_cmdtail_seg:	dw	0

; --- AH=31: Terminate and Stay Resident ---
; Input: AL = return code, DX = paragraphs to keep resident
.i21_31:
	xor	ah, ah
	mov	[cs:last_return_code], ax
	; Resize the program's memory block to DX paragraphs
	mov	bx, dx
	push	es
	mov	es, [cs:exec_seg]
	mov	ah, 0x4A
	int	0x21
	pop	es
	; Close file handles 5+ (like AH=4Ch)
	push	bx
	push	es
	mov	es, [cs:exec_seg]
	mov	bx, 5
.i21_31_close:
	cmp	bx, MAX_HANDLES
	jae	.i21_31_closed
	cmp	byte [es:0x18 + bx], 0xFF
	je	.i21_31_close_next
	push	bx
	mov	ah, 0x3E
	int	0x21
	pop	bx
.i21_31_close_next:
	inc	bx
	jmp	.i21_31_close
.i21_31_closed:
	pop	es
	pop	bx
	; Return to shell WITHOUT freeing memory or restoring vectors
	; The TSR's interrupt hooks stay active
	mov	ax, [cs:shell_psp_seg]
	mov	[cs:exec_seg], ax
	mov	word [cs:dta_seg], SHELL_SEG
	mov	word [cs:dta_off], 0x0080
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax
	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti
	jmp	cmd_loop

; --- AH=4C: Terminate with return code ---
.i21_4c:
	; Save return code
	xor	ah, ah
	mov	[cs:last_return_code], ax
	; Close file handles opened by the child (walk child's JFT)
	; Only close handles 5+ that the child has open
	push	bx
	push	es
	mov	es, [cs:exec_seg]
	mov	bx, 5
.i21_4c_close:
	cmp	bx, MAX_HANDLES
	jae	.i21_4c_closed
	cmp	byte [es:0x18 + bx], 0xFF
	je	.i21_4c_close_next
	; This handle is open — close it properly via AH=3E
	push	bx
	mov	ah, 0x3E
	int	0x21
	pop	bx
.i21_4c_close_next:
	inc	bx
	jmp	.i21_4c_close
.i21_4c_closed:
	pop	es
	pop	bx
	; Free program's memory before returning to shell
	; Free all blocks owned by exec_seg (the program's PSP segment)
	push	es
	push	dx
	mov	dx, [cs:exec_seg]	; DX = program's PSP segment
	mov	ax, [cs:mcb_first]
.i21_4c_free_loop:
	mov	es, ax
	cmp	byte [es:0x00], 'M'
	je	.i21_4c_check
	cmp	byte [es:0x00], 'Z'
	je	.i21_4c_check
	jmp	.i21_4c_go		; Corrupt MCB — just exit
.i21_4c_check:
	cmp	[es:0x01], dx		; Owner == program's PSP?
	jne	.i21_4c_next
	mov	word [es:0x01], 0	; Free it
.i21_4c_next:
	cmp	byte [es:0x00], 'Z'
	je	.i21_4c_merge
	mov	bx, [es:0x03]
	add	ax, bx
	inc	ax
	jmp	.i21_4c_free_loop
.i21_4c_merge:
	call	.mcb_merge_free
.i21_4c_go:
	pop	dx
	pop	es

	; Check if this was an EXEC-launched child
	cmp	byte [cs:exec_depth], 0
	je	.i21_4c_to_shell

	; Return to parent program
	dec	byte [cs:exec_depth]
	; Restore parent's exec_seg
	mov	ax, [cs:.i21_4b_parent_seg]
	mov	[cs:exec_seg], ax
	; Restore BIOS vectors
	call	int20_handler_restore_vectors
	; Restore parent SS:SP and return
	cli
	mov	ss, [cs:exec_parent_ss]
	mov	sp, [cs:exec_parent_sp]
	sti
	; Restore DTA to parent PSP:80
	mov	ax, [cs:exec_seg]
	mov	[cs:dta_seg], ax
	mov	word [cs:dta_off], 0x0080
	; Return to parent with CF=0
	; The parent's stack has FLAGS, CS, IP from INT 21h
	; We need to clear carry in the saved flags
	push	bp
	mov	bp, sp
	and	word [bp+6], 0xFFFE	; Clear CF
	pop	bp
	mov	ax, [cs:last_return_code]
	iret

.i21_4c_to_shell:
	; Fall through to int20_handler (shell-launched program)

; Entry point for INT 20h / INT 22h program termination
int20_handler:
	call	int20_handler_restore_vectors
	; Restore exec_seg to the shell's own PSP
	mov	ax, [cs:shell_psp_seg]
	mov	[cs:exec_seg], ax
	; Restore DTA to shell default
	mov	word [cs:dta_seg], SHELL_SEG
	mov	word [cs:dta_off], 0x0080
	; Restore shell state and return
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax
	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti
	jmp	cmd_loop

; Subroutine: restore BIOS + DOS vectors
int20_handler_restore_vectors:
	xor	ax, ax
	mov	es, ax
	; Restore BIOS vectors
	mov	ax, [cs:saved_int08]
	mov	[es:0x20], ax
	mov	ax, [cs:saved_int08+2]
	mov	[es:0x22], ax
	mov	ax, [cs:saved_int09]
	mov	[es:0x24], ax
	mov	ax, [cs:saved_int09+2]
	mov	[es:0x26], ax
	mov	ax, [cs:saved_int10]
	mov	[es:0x40], ax
	mov	ax, [cs:saved_int10+2]
	mov	[es:0x42], ax
	mov	ax, [cs:saved_int1c]
	mov	[es:0x70], ax
	mov	ax, [cs:saved_int1c+2]
	mov	[es:0x72], ax
	; Restore DOS vectors (preserves TSR hooks)
	mov	ax, [cs:saved_int20]
	mov	[es:0x80], ax
	mov	ax, [cs:saved_int20+2]
	mov	[es:0x82], ax
	mov	ax, [cs:saved_int21]
	mov	[es:0x84], ax
	mov	ax, [cs:saved_int21+2]
	mov	[es:0x86], ax
	mov	ax, [cs:saved_int22]
	mov	[es:0x88], ax
	mov	ax, [cs:saved_int22+2]
	mov	[es:0x8A], ax
	mov	ax, [cs:saved_int23]
	mov	[es:0x8C], ax
	mov	ax, [cs:saved_int23+2]
	mov	[es:0x8E], ax
	mov	ax, [cs:saved_int24]
	mov	[es:0x90], ax
	mov	ax, [cs:saved_int24+2]
	mov	[es:0x92], ax
	ret

; ============================================================================
; Utility: print null-terminated string at DS:SI
; ============================================================================
; ============================================================================
; get_fat_timestamp — get current date/time in FAT format
; Output: cur_fat_time and cur_fat_date populated
; Uses INT 1Ah AH=04 (date) and AH=02 (time)
; Falls back to a default if RTC not available
; ============================================================================
get_fat_timestamp:
	push	ax
	push	bx
	push	cx
	push	dx
	; Try to get date from RTC
	mov	ah, 0x04
	int	0x1A
	jc	.gft_default		; RTC not available
	; CH=century BCD, CL=year BCD, DH=month BCD, DL=day BCD
	; Convert BCD year to binary
	mov	al, cl
	call	.bcd_to_bin
	mov	bl, al			; BL = year (0-99)
	; Convert BCD month
	mov	al, dh
	call	.bcd_to_bin
	mov	bh, al			; BH = month
	; Convert BCD day
	mov	al, dl
	call	.bcd_to_bin
	mov	cl, al			; CL = day
	; FAT date: ((year-80) << 9) | (month << 5) | day
	; Assuming 2000s: year = BL + 20
	xor	ax, ax
	mov	al, bl
	add	ax, 20			; year since 1980
	mov	dx, ax
	mov	cl, 9
	shl	dx, cl
	xor	ax, ax
	mov	al, bh			; month
	mov	cl, 5
	shl	ax, cl
	or	dx, ax
	mov	al, cl			; day... wait, CL was clobbered
	; Let me redo this more carefully
	jmp	.gft_default		; Punt for now, use simpler approach

.gft_default:
	; Get time from RTC
	mov	ah, 0x02
	int	0x1A
	jc	.gft_fallback
	; CH=hour BCD, CL=min BCD, DH=sec BCD
	mov	al, ch
	call	.bcd_to_bin
	mov	bl, al			; hour
	mov	al, cl
	call	.bcd_to_bin
	mov	bh, al			; minute
	mov	al, dh
	call	.bcd_to_bin
	mov	cl, al			; second

	; FAT time: (hour << 11) | (minute << 5) | (second/2)
	xor	ax, ax
	mov	al, bl
	push	cx
	mov	cl, 11
	shl	ax, cl
	pop	cx
	push	ax
	xor	ax, ax
	mov	al, bh
	push	cx
	mov	cl, 5
	shl	ax, cl
	pop	cx
	pop	dx
	or	ax, dx
	shr	cl, 1
	xor	ch, ch
	or	ax, cx
	mov	[cur_fat_time], ax

	; Get date
	mov	ah, 0x04
	int	0x1A
	jc	.gft_date_fallback
	; CH=century BCD, CL=year BCD, DH=month BCD, DL=day BCD
	push	dx
	mov	al, ch
	call	.bcd_to_bin
	mov	bl, al			; century
	mov	al, cl
	call	.bcd_to_bin
	; Full year = century*100 + year
	xor	ah, ah
	push	ax			; save year part
	xor	ax, ax
	mov	al, bl
	mov	cl, 100
	mul	cl
	pop	cx			; year part
	add	ax, cx			; AX = full year (e.g. 2026)
	sub	ax, 1980		; years since 1980
	push	cx
	mov	cl, 9
	shl	ax, cl
	pop	cx
	mov	bx, ax			; save shifted year
	pop	dx			; restore DH=month, DL=day
	mov	al, dh
	call	.bcd_to_bin
	xor	ah, ah
	push	cx
	mov	cl, 5
	shl	ax, cl
	pop	cx
	or	bx, ax
	mov	al, dl
	call	.bcd_to_bin
	xor	ah, ah
	or	bx, ax
	mov	[cur_fat_date], bx
	jmp	.gft_done

.gft_date_fallback:
	mov	word [cur_fat_date], ((2026-1980) << 9) | (4 << 5) | 14
	jmp	.gft_done

.gft_fallback:
	mov	word [cur_fat_time], (12 << 11) | (0 << 5) | 0
	mov	word [cur_fat_date], ((2026-1980) << 9) | (4 << 5) | 14

.gft_done:
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

.bcd_to_bin:
	; Convert BCD byte in AL to binary in AL
	push	cx
	mov	cl, al
	shr	al, 1
	shr	al, 1
	shr	al, 1
	shr	al, 1
	mov	ch, 10
	mul	ch
	and	cl, 0x0F
	add	al, cl
	pop	cx
	ret

cur_fat_time:	dw	0
cur_fat_date:	dw	0

; ============================================================================
; INT 23h — Ctrl-C handler
; ============================================================================
; Default handler: return to shell command loop
int23_handler:
	; Restore shell state and return to command loop
	mov	ax, SHELL_SEG
	mov	ds, ax
	mov	es, ax
	cli
	mov	ss, ax
	mov	sp, 0xFFFE
	sti
	jmp	cmd_loop

; ============================================================================
; INT 24h — Critical error handler
; ============================================================================
; Default handler: return AL=3 (fail the call)
int24_handler:
	mov	al, 3		; Fail
	iret

; ============================================================================
; handle_to_sft — Convert handle number to SFT table offset
; ============================================================================
; Input:  BX = handle number
; Output: BX = SFT table offset (handle * FH_SIZE), or CF=1 if invalid
;         Also checks JFT for DUP'd handles
; Preserves all other registers
; handle_to_sft — Convert handle number to SFT table offset
; Input:  BX = handle number
; Output: SI = SFT table offset, CF=0 on success
;         CF=1 if invalid/closed handle
; Preserves: AX, CX, DX, DI, ES
handle_to_sft:
	cmp	bx, MAX_HANDLES
	jae	.hts_bad
	push	es
	push	bx
	mov	es, [cs:exec_seg]
	mov	bl, [es:0x18 + bx]	; BL = SFT index from JFT
	cmp	bl, 0xFF
	je	.hts_bad_pop
	xor	bh, bh
	mov	si, bx
	push	cx
	mov	cl, 4
	shl	si, cl			; SI = SFT index * 16
	pop	cx
	pop	bx
	pop	es
	clc
	ret
.hts_bad_pop:
	pop	bx
	pop	es
.hts_bad:
	stc
	ret

; shell_putc: output character in AL through stdout (INT 21h AH=02)
; This ensures all shell output goes through handle 1 for redirection
shell_putc:
	push	ax
	push	dx
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	dx
	pop	ax
	ret

; shell_crlf: output CR+LF through stdout
shell_crlf:
	push	ax
	mov	al, 0x0D
	call	shell_putc
	mov	al, 0x0A
	call	shell_putc
	pop	ax
	ret

; shell_beep: short beep via PC speaker (PIT Timer 2)
shell_beep:
	push	ax
	push	cx
	; Set PIT Timer 2, mode 3, 1000 Hz (divider 1193)
	mov	al, 0xB6
	out	0x43, al
	mov	al, 0xA9		; 1193 low byte
	out	0x42, al
	mov	al, 0x04		; 1193 high byte
	out	0x42, al
	; Speaker on
	in	al, 0x61
	or	al, 0x03
	out	0x61, al
	; Short delay (~50ms worth of loop iterations)
	mov	cx, 0x2000
.beep_delay:
	dec	cx
	jnz	.beep_delay
	; Speaker off
	in	al, 0x61
	and	al, 0xFC
	out	0x61, al
	pop	cx
	pop	ax
	ret

print_string:
	push	ax
.ps_loop:
	lodsb
	or	al, al
	jz	.ps_done
	call	shell_putc
	jmp	.ps_loop
.ps_done:
	pop	ax
	ret

; ============================================================================
; Utility: read line from keyboard into ES:DI
; ============================================================================
read_line:
	push	ax
	push	cx
	mov	cx, 0			; Character count

.rl_loop:
	mov	ah, 0x00
	int	0x16			; Wait for key
	cmp	al, 0x09		; TAB? (ignore — used by emulator menu)
	je	.rl_loop
	cmp	al, 0x0D		; Enter?
	je	.rl_done
	cmp	al, 0x08		; Backspace?
	je	.rl_backspace
	cmp	cx, MAX_CMD_LEN
	jb	.rl_accept
	; Buffer full — beep via PC speaker
	call	shell_beep
	jmp	.rl_loop
.rl_accept:

	; Store character
	stosb
	inc	cx
	; Echo
	mov	ah, 0x0E
	int	0x10
	jmp	.rl_loop

.rl_backspace:
	cmp	cx, 0
	je	.rl_loop
	dec	di
	dec	cx
	; Erase on screen
	mov	al, 0x08
	mov	ah, 0x0E
	int	0x10
	mov	al, ' '
	mov	ah, 0x0E
	int	0x10
	mov	al, 0x08
	mov	ah, 0x0E
	int	0x10
	jmp	.rl_loop

.rl_done:
	mov	byte [di], 0		; Null terminate
	; Print CR/LF
	mov	al, 0x0D
	mov	ah, 0x0E
	int	0x10
	mov	al, 0x0A
	mov	ah, 0x0E
	int	0x10
	pop	cx
	pop	ax
	ret

; ============================================================================
; Utility: skip spaces at DS:SI, advance SI
; ============================================================================
skip_spaces:
	cmp	byte [si], ' '
	jne	.ss_done
	inc	si
	jmp	skip_spaces
.ss_done:
	ret

; ============================================================================
; Utility: compare command at SI with keyword at DI (case-insensitive)
; ============================================================================
; Returns ZF=1 if match. SI advanced past the command word on match.
str_compare_cmd:
	push	si
	push	di
.scc_loop:
	mov	al, [di]
	or	al, al
	jz	.scc_end_keyword
	mov	ah, [si]
	; Uppercase AH
	cmp	ah, 'a'
	jb	.scc_no_upper
	cmp	ah, 'z'
	ja	.scc_no_upper
	sub	ah, 0x20
.scc_no_upper:
	cmp	al, ah
	jne	.scc_fail
	inc	si
	inc	di
	jmp	.scc_loop

.scc_end_keyword:
	; Keyword matched. Check that next char in input is space, null, or CR
	mov	al, [si]
	cmp	al, 0
	je	.scc_match
	cmp	al, ' '
	je	.scc_match
	cmp	al, 0x0D
	je	.scc_match
	; Not a word boundary — partial match
.scc_fail:
	pop	di
	pop	si
	or	al, 1			; Clear ZF
	ret

.scc_match:
	pop	di
	pop	ax			; Discard saved SI — keep advanced SI
	ret

; ============================================================================
; Utility: print 32-bit decimal number in DX:AX
; ============================================================================
print_decimal_32:
	push	ax
	push	bx
	push	cx
	push	dx

	; Simple approach: repeatedly divide by 10
	mov	cx, 0			; Digit count
	mov	bx, 10

.pd_divide:
	; Divide DX:AX by 10
	push	ax
	mov	ax, dx
	xor	dx, dx
	div	bx			; AX = high / 10, DX = remainder
	mov	word [.pd_temp], ax	; Save high result
	pop	ax
	div	bx			; AX = low / 10, DX = remainder
	push	dx			; Push digit (remainder)
	mov	dx, [.pd_temp]		; Restore high result
	inc	cx

	; Check if quotient is zero
	or	ax, ax
	jnz	.pd_divide
	or	dx, dx
	jnz	.pd_divide

	; Print digits
.pd_print:
	pop	ax
	add	al, '0'
	call	shell_putc
	dec	cx
	jnz	.pd_print

	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

.pd_temp	dw	0

; ============================================================================
; Data
; ============================================================================
msg_banner	db	'Welcome to MegaDOS v1.0', 0x0D, 0x0A
		db	'For the Mega65 Personal Computer', 0x0D, 0x0A
		db	'A free, lightweight MS-DOS compatible OS', 0x0D, 0x0A, 0

; (msg_prompt removed — prompt is now built dynamically with path)

msg_bytes	db	' bytes', 0x0D, 0x0A, 0

msg_files	db	' file(s)', 0x0D, 0x0A, 0
msg_files_fmt	db	' File(s)      ', 0
msg_bytes_free	db	' bytes free', 0x0D, 0x0A, 0
msg_no_mem	db	'Insufficient memory', 0x0D, 0x0A, 0

msg_not_found	db	'File not found', 0x0D, 0x0A, 0
msg_bad_cmd	db	'Bad command or file name', 0x0D, 0x0A, 0
msg_invalid_dir	db	'Invalid directory', 0x0D, 0x0A, 0

msg_disk_err	db	'Disk read error', 0x0D, 0x0A, 0
msg_need_fname	db	'Required parameter missing', 0x0D, 0x0A, 0
msg_deleted	db	'File deleted', 0x0D, 0x0A, 0
msg_renamed	db	'File renamed', 0x0D, 0x0A, 0
msg_ren_usage	db	'Usage: REN oldname newname', 0x0D, 0x0A, 0
msg_ren_exists	db	'Duplicate file name or File not found', 0x0D, 0x0A, 0
msg_mkdir_exists db	'Unable to create directory', 0x0D, 0x0A, 0
msg_copy_usage	db	'Usage: COPY source dest', 0x0D, 0x0A, 0
msg_copy_ok1	db	'        ', 0
msg_copy_ok2	db	' byte(s) copied', 0x0D, 0x0A, 0
msg_disk_full	db	'Insufficient disk space', 0x0D, 0x0A, 0
msg_dir_full	db	'Directory full', 0x0D, 0x0A, 0
msg_mkdir_ok	db	'Directory created', 0x0D, 0x0A, 0
msg_rmdir_ok	db	'Directory removed', 0x0D, 0x0A, 0
msg_rmdir_not_empty db	'Directory not empty', 0x0D, 0x0A, 0
msg_pause	db	'Press any key to continue...', 0

autoexec_name	db	'AUTOEXEC.BAT', 0
msg_ver		db	0x0D, 0x0A, 'MegaDOS Version 1.0', 0x0D, 0x0A, 0
msg_ver_short	db	'MegaDOS v1.0', 0x0D, 0x0A, 0
msg_cd_root	db	'\', 0
msg_dir_tag	db	'  <DIR>', 0x0D, 0x0A, 0
msg_dir_tag_fmt	db	' <DIR>       ', 0
msg_vol_hdr	db	' Volume in drive has no label', 0x0D, 0x0A, 0
msg_vol_is	db	' Volume in drive is ', 0
msg_dir_of	db	' Directory of  ', 0

cmd_dir		db	'DIR', 0
cmd_echo	db	'ECHO', 0
cmd_cls		db	'CLS', 0
cmd_ver		db	'VER', 0
cmd_type	db	'TYPE', 0
cmd_del		db	'DEL', 0
cmd_ren		db	'REN', 0
cmd_copy	db	'COPY', 0
cmd_cd		db	'CD', 0
cmd_mkdir	db	'MKDIR', 0
cmd_rmdir	db	'RMDIR', 0
cmd_set		db	'SET', 0
cmd_date	db	'DATE', 0
cmd_time	db	'TIME', 0
cmd_prompt	db	'PROMPT', 0
cmd_path	db	'PATH', 0

; ============================================================================
; I/O Redirection
; ============================================================================

; redir_parse: scan cmd_buffer for >, >>, < and extract filenames
; Strips redirect syntax from cmd_buffer so commands don't see it
redir_parse:
	mov	byte [redir_out_mode], 0	; 0=none, 1=create, 2=append
	mov	byte [redir_in_active], 0
	mov	byte [redir_out_fname], 0
	mov	byte [redir_in_fname], 0
	mov	si, cmd_buffer
.rp_scan:
	lodsb
	cmp	al, 0
	je	.rp_done
	cmp	al, '>'
	je	.rp_out
	cmp	al, '<'
	je	.rp_in
	jmp	.rp_scan
.rp_out:
	; Check for >> (append)
	cmp	byte [si], '>'
	jne	.rp_out_create
	inc	si		; Skip second >
	mov	byte [redir_out_mode], 2
	jmp	.rp_out_copy
.rp_out_create:
	mov	byte [redir_out_mode], 1
.rp_out_copy:
	; Null-terminate cmd_buffer at the '>' position
	mov	byte [si-1], 0
	cmp	byte [redir_out_mode], 2
	jne	.rp_out_copy2
	mov	byte [si-2], 0		; Also null the first > for >>
.rp_out_copy2:
	; Skip spaces
.rp_out_skip:
	cmp	byte [si], ' '
	jne	.rp_out_fname
	inc	si
	jmp	.rp_out_skip
.rp_out_fname:
	mov	di, redir_out_fname
.rp_out_fc:
	lodsb
	cmp	al, ' '
	je	.rp_out_fc_done
	cmp	al, '<'
	je	.rp_out_fc_in	; Output then input on same line
	cmp	al, 0
	je	.rp_out_fc_done
	mov	[di], al
	inc	di
	jmp	.rp_out_fc
.rp_out_fc_in:
	mov	byte [di], 0
	jmp	.rp_in		; Continue parsing input redirect
.rp_out_fc_done:
	mov	byte [di], 0
	cmp	al, 0
	je	.rp_done
	jmp	.rp_scan
.rp_in:
	; Null-terminate cmd_buffer at '<'
	mov	byte [si-1], 0
	; Skip spaces
.rp_in_skip:
	cmp	byte [si], ' '
	jne	.rp_in_fname
	inc	si
	jmp	.rp_in_skip
.rp_in_fname:
	mov	byte [redir_in_active], 1
	mov	di, redir_in_fname
.rp_in_fc:
	lodsb
	cmp	al, ' '
	je	.rp_in_fc_done
	cmp	al, '>'
	je	.rp_in_fc_out
	cmp	al, 0
	je	.rp_in_fc_done
	mov	[di], al
	inc	di
	jmp	.rp_in_fc
.rp_in_fc_out:
	mov	byte [di], 0
	jmp	.rp_out
.rp_in_fc_done:
	mov	byte [di], 0
	cmp	al, 0
	je	.rp_done
	jmp	.rp_scan
.rp_done:
	; Strip trailing spaces from cmd_buffer
	mov	si, cmd_buffer
.rp_find_end:
	cmp	byte [si], 0
	je	.rp_strip
	inc	si
	jmp	.rp_find_end
.rp_strip:
	dec	si
	cmp	si, cmd_buffer
	jb	.rp_ret
	cmp	byte [si], ' '
	jne	.rp_ret
	mov	byte [si], 0
	jmp	.rp_strip
.rp_ret:
	ret

; redir_activate: open redirect files and swap handles
redir_activate:
	; Save original JFT entries for handles 0 and 1
	push	es
	mov	es, [exec_seg]
	mov	al, [es:0x18]		; JFT[0] = stdin SFT index
	mov	[redir_save_stdin], al
	mov	al, [es:0x19]		; JFT[1] = stdout SFT index
	mov	[redir_save_stdout], al
	pop	es

	; Handle output redirection
	cmp	byte [redir_out_mode], 0
	je	.ra_no_out
	cmp	byte [redir_out_mode], 2
	je	.ra_append
	; Create/truncate
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, redir_out_fname
	int	0x21
	jc	.ra_out_err
	mov	[redir_out_handle], ax
	jmp	.ra_out_dup
.ra_append:
	; Open for write, seek to end
	mov	ah, 0x3D
	mov	al, 1		; Write
	mov	dx, redir_out_fname
	int	0x21
	jc	.ra_out_create	; File doesn't exist — create it
	mov	[redir_out_handle], ax
	; Seek to end
	mov	bx, ax
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.ra_out_fail_close
	jmp	.ra_out_dup
.ra_out_create:
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, redir_out_fname
	int	0x21
	jc	.ra_out_err
	mov	[redir_out_handle], ax
.ra_out_dup:
	; DUP2: make handle 1 (stdout) point to the file
	mov	bx, [redir_out_handle]
	mov	cx, 1
	mov	ah, 0x46
	int	0x21
	jc	.ra_out_fail_close
	jmp	.ra_no_out
.ra_out_fail_close:
	; DUP2 failed — close the file and cancel redirection
	mov	bx, [redir_out_handle]
	mov	ah, 0x3E
	int	0x21
.ra_out_err:
	mov	byte [redir_out_mode], 0
.ra_no_out:

	; Handle input redirection
	cmp	byte [redir_in_active], 0
	je	.ra_no_in
	mov	ah, 0x3D
	mov	al, 0		; Read
	mov	dx, redir_in_fname
	int	0x21
	jc	.ra_in_err
	mov	[redir_in_handle], ax
	; DUP2: make handle 0 (stdin) point to the file
	mov	bx, ax
	mov	cx, 0
	mov	ah, 0x46
	int	0x21
	jc	.ra_in_fail_close
	jmp	.ra_no_in
.ra_in_fail_close:
	mov	bx, [redir_in_handle]
	mov	ah, 0x3E
	int	0x21
.ra_in_err:
	mov	byte [redir_in_active], 0
.ra_no_in:
	ret

; redir_restore: restore original handles if redirection was active
redir_restore:
	push	es

	; Restore stdout
	cmp	byte [redir_out_mode], 0
	je	.rr_no_out

	; Close handle 1 (redirected stdout alias) — refcount 2→1
	mov	bx, 1
	mov	ah, 0x3E
	int	0x21

	; Close the original redirect file handle — refcount 1→0, triggers dir update
	mov	bx, [redir_out_handle]
	mov	ah, 0x3E
	int	0x21

	; Restore original stdout JFT entry
	mov	es, [exec_seg]
	mov	al, [redir_save_stdout]
	mov	[es:0x19], al

	mov	byte [redir_out_mode], 0
.rr_no_out:

	; Restore stdin
	cmp	byte [redir_in_active], 0
	je	.rr_no_in

	; Close handle 0 (redirected stdin alias)
	mov	bx, 0
	mov	ah, 0x3E
	int	0x21

	; Close the original redirect input handle
	mov	bx, [redir_in_handle]
	mov	ah, 0x3E
	int	0x21

	; Restore original stdin JFT entry
	mov	es, [exec_seg]
	mov	al, [redir_save_stdin]
	mov	[es:0x18], al

	mov	byte [redir_in_active], 0
.rr_no_in:
	pop	es
	ret

; Redirection variables
redir_out_mode:		db	0	; 0=none, 1=create, 2=append
redir_in_active:	db	0
redir_out_handle:	dw	0
redir_in_handle:	dw	0
redir_save_stdin:	db	0
redir_save_stdout:	db	0
redir_out_fname:	times 78 db 0
redir_in_fname:		times 78 db 0
redir_cmd_save:		times MAX_CMD_LEN + 1 db 0

; ============================================================================
; search_path — Search PATH directories for the current exec_fname
; ============================================================================
; Reads PATH= from environment, tries each directory
; On success: cmd_buffer has the full path, CF=0
; On failure: CF=1
search_path:
	; Save the original command name from cmd_buffer
	mov	si, cmd_buffer
	mov	di, path_cmd_save
	mov	cx, MAX_CMD_LEN + 1
	rep	movsb

	; Find PATH= in environment
	mov	es, [env_seg]
	xor	si, si
.sp_scan:
	cmp	byte [es:si], 0		; End of env
	je	.sp_not_found
	; Check for PATH= (case-insensitive)
	mov	al, [es:si]
	and	al, 0xDF		; Uppercase
	cmp	al, 'P'
	jne	.sp_skip
	mov	al, [es:si+1]
	and	al, 0xDF
	cmp	al, 'A'
	jne	.sp_skip
	mov	al, [es:si+2]
	and	al, 0xDF
	cmp	al, 'T'
	jne	.sp_skip
	mov	al, [es:si+3]
	and	al, 0xDF
	cmp	al, 'H'
	jne	.sp_skip
	cmp	byte [es:si+4], '='
	jne	.sp_skip
	add	si, 5			; SI past "PATH="
	jmp	.sp_try_dirs
.sp_skip:
	cmp	byte [es:si], 0
	je	.sp_skip_next
	inc	si
	jmp	.sp_skip
.sp_skip_next:
	inc	si
	jmp	.sp_scan

.sp_try_dirs:
	; ES:SI points into PATH value (e.g., "A:\;A:\BIN;A:\UTILS")
.sp_next_dir:
	cmp	byte [es:si], 0
	je	.sp_not_found

	; Build full path: directory + \ + command name
	mov	di, cmd_buffer
.sp_copy_dir:
	mov	al, [es:si]
	cmp	al, 0
	je	.sp_dir_done
	cmp	al, ';'
	je	.sp_dir_sep
	; Uppercase the path character
	cmp	al, 'a'
	jb	.sp_no_upper
	cmp	al, 'z'
	ja	.sp_no_upper
	sub	al, 0x20
.sp_no_upper:
	mov	[di], al
	inc	di
	inc	si
	jmp	.sp_copy_dir
.sp_dir_sep:
	inc	si
.sp_dir_done:
	; Add backslash if not already there
	cmp	byte [di-1], '\'
	je	.sp_has_slash
	mov	byte [di], '\'
	inc	di
.sp_has_slash:
	; Append command name (just name, no args) + command tail
	push	si
	push	es
	push	ds
	pop	es			; ES = DS = SHELL_SEG
	mov	si, path_cmd_save
.sp_copy_cmd:
	lodsb
	cmp	al, 0
	je	.sp_cmd_end
	mov	[di], al
	inc	di
	jmp	.sp_copy_cmd
.sp_cmd_end:
	mov	byte [di], 0
	pop	es
	pop	si

	; Search the PATH directory for the executable.
	; cmd_buffer has the full path. Walk directory components,
	; then search the target directory for the file.
	mov	[sp_env_si], si		; Save env position
	mov	[sp_env_es], es		; Save env segment

	; Set up drive and starting directory from cmd_buffer
	mov	si, cmd_buffer
	mov	al, [cur_drive]
	mov	[resolved_drive], al

	; Check for drive letter
	cmp	byte [si+1], ':'
	jne	.sp_no_drv
	mov	al, [si]
	cmp	al, 'a'
	jb	.sp_drv_ok
	sub	al, 0x20
.sp_drv_ok:
	sub	al, 'A'
	mov	[resolved_drive], al
	add	si, 2
.sp_no_drv:
	; Check for absolute path
	cmp	byte [si], '\'
	jne	.sp_rel_dir
	mov	word [resolved_dir_cluster], 0
	mov	word [resolved_dir_entries], MAX_DIR_ENTRIES
	inc	si
	jmp	.sp_walk_path
.sp_rel_dir:
	mov	ax, [cur_dir_cluster]
	mov	[resolved_dir_cluster], ax
	mov	ax, [cur_dir_entries]
	mov	[resolved_dir_entries], ax

.sp_walk_path:
	; SI points into the remaining path in cmd_buffer
	; Check if there's a backslash remaining (meaning more dirs to descend)
	mov	di, si
	xor	bx, bx
.sp_check_bs:
	cmp	byte [di], 0
	je	.sp_check_bs_done
	cmp	byte [di], '\'
	jne	.sp_check_bs_next
	mov	bx, 1
.sp_check_bs_next:
	inc	di
	jmp	.sp_check_bs
.sp_check_bs_done:
	cmp	bx, 0
	je	.sp_at_target_dir

	; Manually parse directory name from SI into exec_fname
	mov	di, exec_fname
	push	cx
	push	es
	push	ds
	pop	es			; ES = DS = SHELL_SEG for stosb
	; Fill with spaces
	push	di
	mov	al, ' '
	mov	cx, 11
	rep	stosb
	pop	di
	; Copy name chars until \ or null, uppercasing
	mov	cx, 8
.sp_parse_dir:
	mov	al, [si]
	cmp	al, 0
	je	.sp_parse_dir_done
	cmp	al, '\'
	je	.sp_parse_dir_done
	cmp	al, ' '
	je	.sp_parse_dir_done
	cmp	al, 'a'
	jb	.sp_parse_dir_store
	cmp	al, 'z'
	ja	.sp_parse_dir_store
	sub	al, 0x20
.sp_parse_dir_store:
	mov	[di], al
	inc	si
	inc	di
	dec	cx
	jnz	.sp_parse_dir
.sp_parse_dir_done:
	pop	es
	pop	cx
	; Skip backslash
	cmp	byte [si], '\'
	jne	.sp_at_target_dir
	inc	si
	mov	[sp_path_si], si	; Save position for after dir lookup

	; Read current resolved directory
	call	read_resolved_dir
	jc	.sp_try_fail
	; Search for this directory entry
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	mov	ax, SHELL_SEG
	mov	es, ax
.sp_dir_search:
	cmp	byte [si], 0
	je	.sp_try_fail
	cmp	byte [si], 0xE5
	je	.sp_dir_next
	test	byte [si+11], 0x10
	jz	.sp_dir_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.sp_dir_found
.sp_dir_next:
	add	si, 32
	dec	cx
	jnz	.sp_dir_search
	jmp	.sp_try_fail
.sp_dir_found:
	; Descend
	mov	ax, [si+26]
	mov	[resolved_dir_cluster], ax
	mov	word [resolved_dir_entries], (SECS_PER_CLUST * 512) / 32
	mov	si, [sp_path_si]
	jmp	.sp_walk_path

.sp_at_target_dir:
	; We're at the target directory. Parse the command name.
	mov	ax, SHELL_SEG
	mov	es, ax			; Ensure ES = SHELL_SEG for parse_83_filename
	mov	si, path_cmd_save
	mov	di, exec_fname
	call	parse_83_filename

	; Read the target directory
	call	read_resolved_dir
	jc	.sp_try_fail

	; Try .COM first
	cmp	byte [exec_fname+8], ' '
	jne	.sp_has_ext
	mov	byte [exec_fname+8], 'C'
	mov	byte [exec_fname+9], 'O'
	mov	byte [exec_fname+10], 'M'
.sp_has_ext:
	mov	ax, SHELL_SEG
	mov	es, ax
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
.sp_file_search:
	cmp	byte [si], 0
	je	.sp_try_ext
	cmp	byte [si], 0xE5
	je	.sp_file_next
	push	cx
	push	si
	mov	di, exec_fname
	mov	cx, 11
	repe	cmpsb
	pop	si
	pop	cx
	je	.sp_file_found
.sp_file_next:
	add	si, 32
	dec	cx
	jnz	.sp_file_search
.sp_try_ext:
	cmp	byte [exec_fname+8], 'C'
	jne	.sp_try_exe
	mov	byte [exec_fname+8], 'E'
	mov	byte [exec_fname+9], 'X'
	mov	byte [exec_fname+10], 'E'
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.sp_file_search
.sp_try_exe:
	cmp	byte [exec_fname+8], 'E'
	jne	.sp_try_fail
	mov	byte [exec_fname+8], 'B'
	mov	byte [exec_fname+9], 'A'
	mov	byte [exec_fname+10], 'T'
	mov	si, dir_buffer
	mov	cx, [resolved_dir_entries]
	jmp	.sp_file_search

.sp_try_fail:
	mov	si, [sp_env_si]
	mov	es, [sp_env_es]
	jmp	.sp_next_dir

.sp_file_found:
	; File exists in this PATH directory!

.sp_found:
	; resolved_dir_cluster/entries and exec_fname are set
	clc
	ret

.sp_not_found:
	stc
	ret

path_searched:	db	0
sp_saved_char:	db	0
exec_empty_tail: db	0
sp_env_si:	dw	0
sp_env_es:	dw	0
sp_path_si:	dw	0
path_cmd_save:	times MAX_CMD_LEN + 1 db 0

; ============================================================================
; process_config_sys — Read and process CONFIG.SYS at boot
; ============================================================================
process_config_sys:
	; Try to open CONFIG.SYS
	mov	ah, 0x3D
	mov	al, 0			; Read only
	mov	dx, config_sys_name
	int	0x21
	jc	.cfg_done		; File not found — skip silently
	mov	[.cfg_handle], ax

	; Read and process line by line
.cfg_read_line:
	mov	di, cfg_line_buf
	mov	cx, MAX_CMD_LEN
.cfg_read_char:
	push	cx
	mov	ah, 0x3F
	mov	bx, [.cfg_handle]
	mov	cx, 1
	mov	dx, .cfg_char
	int	0x21
	pop	cx
	cmp	ax, 0			; EOF
	je	.cfg_eof
	mov	al, [.cfg_char]
	cmp	al, 0x0D		; CR
	je	.cfg_cr
	cmp	al, 0x0A		; LF = end of line
	je	.cfg_process_line
	cmp	al, 0x1A		; Ctrl-Z
	je	.cfg_eof
	mov	[di], al
	inc	di
	dec	cx
	jnz	.cfg_read_char
.cfg_cr:
	; Skip LF after CR
	push	cx
	mov	ah, 0x3F
	mov	bx, [.cfg_handle]
	mov	cx, 1
	mov	dx, .cfg_char
	int	0x21
	pop	cx
.cfg_process_line:
	mov	byte [di], 0
	call	.cfg_parse_line
	jmp	.cfg_read_line

.cfg_eof:
	; Process any remaining partial line
	cmp	di, cfg_line_buf
	je	.cfg_close
	mov	byte [di], 0
	call	.cfg_parse_line
.cfg_close:
	mov	ah, 0x3E
	mov	bx, [.cfg_handle]
	int	0x21
.cfg_done:
	ret

.cfg_handle:	dw	0
.cfg_char:	db	0

; Parse one CONFIG.SYS line from cfg_line_buf
.cfg_parse_line:
	mov	si, cfg_line_buf
	call	skip_spaces
	; Skip empty lines and comments (lines starting with ;)
	cmp	byte [si], 0
	je	.cfg_line_done
	cmp	byte [si], ';'
	je	.cfg_line_done

	; Check for DEVICE=
	push	si
	mov	di, .cfg_str_device
	call	.cfg_match_keyword
	je	.cfg_device_match
	pop	si

	; Check for FILES=
	push	si
	mov	di, .cfg_str_files
	call	.cfg_match_keyword
	je	.cfg_files_match
	pop	si

	; Check for BREAK=
	push	si
	mov	di, .cfg_str_break
	call	.cfg_match_keyword
	je	.cfg_break_match
	pop	si

	; Check for BUFFERS= (accept but ignore)
	; Check for LASTDRIVE= (accept but ignore)
	; Check for SHELL= (accept but ignore — we are the shell)
	; Check for COUNTRY= (accept but ignore)

	; Unknown directive — ignore
.cfg_line_done:
	ret

.cfg_device_match:
	pop	ax			; Discard saved SI
	jmp	.cfg_device
.cfg_files_match:
	pop	ax
	jmp	.cfg_files
.cfg_break_match:
	pop	ax
	jmp	.cfg_break

; --- DEVICE= handler ---
.cfg_device:
	; SI points past "DEVICE="
	; Load the .SYS file and initialize it
	call	skip_spaces

	; Copy filename to cfg_fname (AH=3Dh will overwrite cmd_buffer)
	push	si
	mov	di, cfg_fname
.cfg_copy_fname:
	lodsb
	mov	[di], al
	inc	di
	cmp	al, ' '
	je	.cfg_fname_end
	or	al, al
	jnz	.cfg_copy_fname
.cfg_fname_end:
	mov	byte [di-1], 0
	pop	si

	; Try to open the driver file
	mov	dx, cfg_fname		; DS:DX = filename
	mov	ah, 0x3D
	mov	al, 0
	int	0x21
	jc	.cfg_dev_err

	mov	[.cfg_dev_handle], ax

	; Allocate memory for the driver
	mov	bx, 0xFFFF
	call	alloc_mem_core		; Probe for largest block
	cmp	bx, 4			; Need at least 64 bytes
	jb	.cfg_dev_no_mem
	call	alloc_mem_core		; Allocate it
	jc	.cfg_dev_no_mem
	mov	[.cfg_dev_seg], ax

	; Read the file into the allocated segment
	mov	es, ax
	xor	di, di
	mov	bx, [.cfg_dev_handle]
.cfg_dev_read:
	push	di
	mov	ah, 0x3F
	mov	cx, 512
	mov	dx, di
	push	ds
	push	es
	pop	ds			; DS = driver segment for read buffer
	int	0x21
	pop	ds
	pop	di
	jc	.cfg_dev_read_err	; Read failed
	cmp	ax, 0
	je	.cfg_dev_read_done
	add	di, ax
	jc	.cfg_dev_read_err	; DI wrapped past 64K
	jmp	.cfg_dev_read
.cfg_dev_read_err:
	; Read failed — close file, free memory, bail
	mov	ah, 0x3E
	mov	bx, [.cfg_dev_handle]
	int	0x21
	push	es
	mov	es, [.cfg_dev_seg]
	mov	ah, 0x49
	int	0x21
	pop	es
	push	si
	mov	si, .cfg_msg_not_found
	call	print_string
	mov	si, cfg_fname
	call	print_string
	call	shell_crlf
	pop	si
	ret
.cfg_dev_read_done:
	; Close the file
	mov	ah, 0x3E
	mov	bx, [.cfg_dev_handle]
	int	0x21

	; Resize memory block to actual size needed
	; DI = bytes read. Convert to paragraphs.
	mov	ax, di
	add	ax, 15
	shr	ax, 1
	shr	ax, 1
	shr	ax, 1
	shr	ax, 1
	mov	bx, ax
	or	bx, bx
	jnz	.cfg_dev_resize
	mov	bx, 1			; At least 1 paragraph
.cfg_dev_resize:
	push	es
	mov	es, [.cfg_dev_seg]
	mov	ah, 0x4A
	int	0x21
	pop	es
	jnc	.cfg_dev_resized
	; Resize failed — warn but continue with oversized block
	push	si
	mov	si, .cfg_msg_resize_warn
	call	print_string
	pop	si
.cfg_dev_resized:
	; Call the driver's INIT function BEFORE linking into chain
	mov	es, [.cfg_dev_seg]
	mov	byte [cs:drv_request], 22
	mov	byte [cs:drv_request+1], 0
	mov	byte [cs:drv_request+2], 0	; Command = INIT
	mov	word [cs:drv_request+3], 0	; Status
	mov	word [cs:drv_request+18], si	; Command line offset
	mov	word [cs:drv_request+20], ds	; Command line segment
	mov	bx, 0			; Driver header at ES:0
	call	drv_call

	; Check INIT status — bit 15 = error
	test	word [cs:drv_request+3], 0x8000
	jnz	.cfg_dev_init_fail

	; INIT succeeded — link driver into chain (insert after NUL)
	mov	es, [.cfg_dev_seg]
	mov	ax, [cs:drv_nul]	; Current NUL→next offset
	mov	[es:0], ax
	mov	ax, [cs:drv_nul+2]	; Current NUL→next segment
	mov	[es:2], ax
	mov	word [cs:drv_nul], 0	; New driver at offset 0 in its segment
	mov	ax, [.cfg_dev_seg]
	mov	[cs:drv_nul+2], ax

	; Refresh CON driver cache (new driver may be a CON replacement)
	call	con_find_con

	; Print driver name
	push	si
	mov	si, .cfg_msg_device
	call	print_string
	push	es
	push	cx
	mov	es, [.cfg_dev_seg]
	mov	si, 10			; Name at header+10
	mov	cx, 8
.cfg_dev_name:
	mov	al, [es:si]
	cmp	al, ' '
	je	.cfg_dev_name_done
	call	shell_putc
	inc	si
	dec	cx
	jnz	.cfg_dev_name
.cfg_dev_name_done:
	pop	cx
	pop	es
	pop	si
	call	shell_crlf
	ret

.cfg_dev_init_fail:
	; INIT failed — free memory, report error
	push	es
	mov	es, [.cfg_dev_seg]
	mov	ah, 0x49
	int	0x21
	pop	es
	push	si
	mov	si, .cfg_msg_init_fail
	call	print_string
	mov	si, cfg_fname
	call	print_string
	call	shell_crlf
	pop	si
	ret

.cfg_dev_err:
	push	si
	mov	si, .cfg_msg_not_found
	call	print_string
	pop	si
	call	print_string
	call	shell_crlf
	ret

.cfg_dev_no_mem:
	; Close file and report error
	mov	ah, 0x3E
	mov	bx, [.cfg_dev_handle]
	int	0x21
	push	si
	mov	si, .cfg_msg_no_mem
	call	print_string
	pop	si
	ret

.cfg_dev_handle: dw	0
.cfg_dev_seg:	dw	0

; --- FILES= handler ---
.cfg_files:
	; SI points past "FILES="
	call	skip_spaces
	; Parse number (ignored for now — MAX_HANDLES is compile-time)
	; Just acknowledge it
	ret

; --- BREAK= handler ---
.cfg_break:
	; SI points past "BREAK="
	call	skip_spaces
	cmp	byte [si], 'O'
	jne	.cfg_break_check_lower
	cmp	byte [si+1], 'N'
	jne	.cfg_break_off
	mov	byte [break_flag], 1
	ret
.cfg_break_check_lower:
	cmp	byte [si], 'o'
	jne	.cfg_break_off
	cmp	byte [si+1], 'n'
	jne	.cfg_break_off
	mov	byte [break_flag], 1
	ret
.cfg_break_off:
	mov	byte [break_flag], 0
	ret

; --- Keyword matcher ---
; Compare SI (input) with DI (keyword), case-insensitive, until '='
; Returns ZF=1 if match, SI advanced past '='
.cfg_match_keyword:
.cfg_mk_loop:
	mov	al, [di]
	cmp	al, 0			; End of keyword
	je	.cfg_mk_check_eq
	mov	ah, [si]
	; Uppercase AH
	cmp	ah, 'a'
	jb	.cfg_mk_cmp
	cmp	ah, 'z'
	ja	.cfg_mk_cmp
	sub	ah, 0x20
.cfg_mk_cmp:
	cmp	al, ah
	jne	.cfg_mk_fail
	inc	si
	inc	di
	jmp	.cfg_mk_loop
.cfg_mk_check_eq:
	cmp	byte [si], '='
	jne	.cfg_mk_fail
	inc	si			; Skip '='
	; Match! ZF=1
	xor	al, al			; Set ZF
	ret
.cfg_mk_fail:
	or	al, 1			; Clear ZF
	ret

.cfg_str_device: db	'DEVICE', 0
.cfg_str_files:	db	'FILES', 0
.cfg_str_break:	db	'BREAK', 0
.cfg_msg_device: db	'  Device: ', 0
.cfg_msg_not_found: db	'  Bad or missing: ', 0
.cfg_msg_no_mem: db	'  Insufficient memory', 0x0D, 0x0A, 0
.cfg_msg_init_fail: db	'  INIT failed: ', 0
.cfg_msg_resize_warn: db	'  Warning: resize failed', 0x0D, 0x0A, 0

config_sys_name: db	'CONFIG.SYS', 0
cfg_line_buf:	times MAX_CMD_LEN+1 db 0
cfg_fname:	times 78 db 0

; ============================================================================
; Variables
; ============================================================================
input_buf:	db	MAX_CMD_LEN	; Max length
		db	0		; Actual length
		times MAX_CMD_LEN+1 db 0 ; Data + CR
cmd_buffer:	times MAX_CMD_LEN+1 db 0
exec_fname:	times 11 db ' '
		db	0		; null terminator
wild_pattern:	times 11 db ' '		; wildcard pattern for DIR/DEL
wild_active:	db	0		; 1 = wildcard filter active
ren_new_fname:	times 11 db ' '
		db	0
cmd_char_count:	dw	0
copy_src_cl:	dw	0
copy_dest_cl:	dw	0
copy_prev_cl:	dw	0
copy_first_cl:	dw	0
copy_dest_dir:	dw	0
copy_src_attr:	db	0
copy_src_dir_cl: dw	0
copy_src_dir_ent: dw	0
copy_dst_dir_cl: dw	0
copy_dst_dir_ent: dw	0
copy_src_drv:	db	0
copy_dst_drv:	db	0
copy_src_name:	times 11 db ' '
; Per-drive current directory state
; Drive A (index 0)
drv_a_cluster:	dw	0
drv_a_entries:	dw	112
drv_a_path:	times 65 db 0
drv_a_pathlen:	db	0
; Drive B (index 1)
drv_b_cluster:	dw	0
drv_b_entries:	dw	112
drv_b_path:	times 65 db 0
drv_b_pathlen:	db	0
; Active drive and current dir pointers (copied from per-drive on switch)
cur_dir_cluster: dw	0
cur_dir_entries: dw	112
cur_dir_path:	times 65 db 0
cur_dir_pathlen: db	0
cur_drive:	db	0		; Current drive (0=A, 1=B)
resolved_dir_cluster: dw 0
resolved_dir_entries: dw 112
resolved_drive:	db	0		; Drive for resolved path
batch_active:	db	0		; Nonzero if executing a batch file
batch_ptr:	dw	0		; Current position in batch buffer
batch_end:	dw	0		; End of batch data
batch_echo:	db	1		; Batch echo state (1=on, 0=off)
mcb_first:	dw	PROG_SEG	; First MCB segment
exec_cluster:	dw	0
exec_size:	dd	0
exec_parent_psp: dw	0		; Saved parent PSP for JFT inherit
shell_psp_seg:	dw	0		; Shell's own PSP segment (never changes)
exec_seg:	dw	0		; Allocated segment for program
		dw	0		; CS for EXE far jump
		dw	0		; IP for EXE far jump
exe_hdr_size:	dw	0
exe_load_seg:	dw	0
exec_jmp_ip:	dw	0x0100		; For far jump to program
exec_jmp_cs:	dw	0
exec_try_ext:	db	0		; 0=done, 1=try EXE, 2=try BAT
exec_cur_sec:	dw	0		; Current linear sector during exec load
exec_parent_ss:	dw	0		; Parent SS for AH=4Bh EXEC return
exec_parent_sp:	dw	0		; Parent SP for AH=4Bh EXEC return
exec_depth:	db	0		; Nesting depth (0=shell launched, >0=EXEC launched)
exec_cmdtail_ptr: dw	0		; Pointer to command tail in cmd_buffer
env_seg:	dw	0		; Segment of environment block
break_flag:	db	0		; Ctrl-C check flag
verify_flag:	db	0		; Disk verify flag
last_error:	dw	0		; Last extended error code

; Environment string data
env_comspec:	db	'COMSPEC=A:\SHELL.COM', 0
env_path:	db	'PATH=A:\', 0
env_prompt:	db	'PROMPT=$P$G', 0
env_progname:	db	'A:\SHELL.COM', 0
last_return_code: dw	0		; Return code from last AH=4C
dta_seg:	dw	0		; DTA segment (default: PSP:0080)
dta_off:	dw	0x0080		; DTA offset

; File handle table — 8 handles (0-7), each 16 bytes
; Handles 0-4 are predefined (stdin/stdout/stderr/stdaux/stdprn)
MAX_HANDLES	equ	20
FH_SIZE		equ	16		; Bytes per handle entry

; Handle entry layout:
;   +0: flags (0=closed, 1=open read, 2=open write, 3=open r/w, 0x80=device)
;   +1: drive (0=A, 1=B)
;   +2-3: start cluster
;   +4-5: current cluster
;   +6-7: position within current cluster (byte offset)
;   +8-11: file pointer (32-bit absolute position)
;   +12-15: file size (32-bit)

file_handles:
	; Handle 0: stdin (device)
	db	0x80, 0, 0,0, 0,0, 0,0, 0,0,0,0, 0,0,0,0
	; Handle 1: stdout (device)
	db	0x80, 0, 0,0, 0,0, 0,0, 0,0,0,0, 0,0,0,0
	; Handle 2: stderr (device)
	db	0x80, 0, 0,0, 0,0, 0,0, 0,0,0,0, 0,0,0,0
	; Handle 3: stdaux (device)
	db	0x80, 0, 0,0, 0,0, 0,0, 0,0,0,0, 0,0,0,0
	; Handle 4: stdprn (device)
	db	0x80, 0, 0,0, 0,0, 0,0, 0,0,0,0, 0,0,0,0
	; Handles 5-7: available for files
	times (MAX_HANDLES - 5) * FH_SIZE db 0
sft_refcount:
	db	1, 1, 1, 1, 1		; Device handles always refcount=1
	times (MAX_HANDLES - 5) db 0	; File handles start at 0
sft_dir_cluster:			; Directory cluster where file entry lives
	dw	0, 0, 0, 0, 0		; Device handles (unused)
	times (MAX_HANDLES - 5) dw 0	; File handles
sft_dir_entries:			; Number of entries in that directory
	dw	0, 0, 0, 0, 0
	times (MAX_HANDLES - 5) dw 0
sft_devinfo:				; IOCTL device info word per SFT entry
	dw	0x80D3			; SFT 0: stdin  (ISDEV|ISCIN|ISCOT|BINARY|SPECIAL)
	dw	0x80D3			; SFT 1: stdout (ISDEV|ISCIN|ISCOT|BINARY|SPECIAL)
	dw	0x80D3			; SFT 2: stderr (ISDEV|ISCIN|ISCOT|BINARY|SPECIAL)
	dw	0x80C0			; SFT 3: stdaux (ISDEV|BINARY)
	dw	0xA0C0			; SFT 4: stdprn (ISDEV|BINARY|NULDEV)
	times (MAX_HANDLES - 5) dw 0	; File handles: 0 = disk file
file_count:	dw	0
dir_wide:	db	0
dir_col:	db	0			; Column counter for wide mode
dir_hdr_path:	times 65 db 0			; Path string for DIR header display

; ============================================================================
; Buffers (must be after all code/data)
; ============================================================================
saved_int08:	dd	0
saved_int09:	dd	0
saved_int10:	dd	0
saved_int1c:	dd	0
saved_int20:	dd	0
saved_int21:	dd	0
saved_int22:	dd	0
saved_int23:	dd	0
saved_int24:	dd	0

		; Buffers are at the start of the file (after jmp start_code)
		; FAT: 2 * 512 = 1024 bytes
