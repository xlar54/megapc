; DEBUG.COM - MegaDOS memory debugger (first-pass DEBUG clone)
; Supported commands:
;   A addr ...           Assemble register/no-memory instruction forms
;   C start end dest    Compare memory
;   D [addr] [end]      Dump memory
;   E addr bytes...     Enter hex bytes
;   F start end byte    Fill range
;   G [addr]            Go
;   H value1 value2     Hex add/subtract
;   I port              Input byte from port
;   L [file [args]]     Load file at target:0100 (EXE aware)
;   M start end dest    Move range
;   N file [args]       Set current file name and target args
;   O port byte         Output byte to port
;   P [addr]            Proceed one instruction
;   R [reg [value]]     Show or edit target registers
;   S start end bytes   Search for hex byte pattern
;   T [addr]            Trace one instruction
;   U [addr [end]]      Unassemble
;   W [addr [len]]      Write bytes to named file
;   R                   Show debugger state
;   ?                   Show help
;   Q                   Quit
;
; Notes:
;   - Numbers are hexadecimal.
;   - Addresses can be OFFSET or SEG:OFFSET.
;   - Supplying SEG:OFFSET updates the default segment for later commands.
;   - Range-style commands currently operate within a single segment.
	cpu	8086
	org	0x0100

INPUT_MAX	equ	126
DUMP_BYTES	equ	128
LINE_BYTES	equ	16
SEARCH_MAX	equ	32
FNAME_MAX	equ	79

; User breakpoint table
BP_COUNT	equ	10
BP_SIZE		equ	6		; per slot: seg(2) off(2) orig(1) flags(1)
BP_F_ACTIVE	equ	0x01		; user set this BP
BP_F_PATCHED	equ	0x02		; bp_install wrote CC this run

MODE_GO		equ	0
MODE_TRACE	equ	1
MODE_PROCEED	equ	2

STOP_TRACE	equ	1
STOP_BREAK	equ	2
STOP_INT20	equ	3
STOP_INT21	equ	4

start:
	mov	[psp_seg], ds
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	; Shrink our memory block so DEBUG.COM stays lightweight.
	mov	ah, 0x4A
	mov	bx, (end_of_prog - start + 0x100 + 15) / 16
	push	cs
	pop	es
	int	0x21

	call	init_target
	jc	start_fail

	mov	si, msg_banner
	call	print_str

	; If a filename was passed on the DEBUG command line (PSP:0x80 tail),
	; copy it into cmd_text, store via store_filename, and jump into the
	; load path so "DEBUG FOO.COM" auto-loads FOO.COM at target:0x100.
	push	ds
	mov	ds, [psp_seg]
	mov	al, [0x80]
	pop	ds
	or	al, al
	jz	main_loop
	xor	ah, ah
	mov	cx, ax
	push	ds
	mov	ds, [psp_seg]
	mov	si, 0x81
	push	cs
	pop	es
	mov	di, cmd_text
.auto_copy:
	mov	al, [si]
	cmp	al, 0x0D
	je	.auto_copy_done
	or	al, al
	jz	.auto_copy_done
	mov	[es:di], al
	inc	si
	inc	di
	loop	.auto_copy
.auto_copy_done:
	mov	byte [es:di], 0
	pop	ds
	mov	si, cmd_text
	call	skip_delims
	cmp	byte [si], 0
	je	main_loop
	; Split filename and args. BX = start of filename; scan SI to the
	; first whitespace/null to find filename end; temporarily null-
	; terminate there, call store_filename, then restore the char.
	mov	bx, si
.auto_fname_end:
	mov	al, [si]
	or	al, al
	je	.auto_have_fname
	cmp	al, ' '
	je	.auto_have_fname
	cmp	al, 9
	je	.auto_have_fname
	inc	si
	jmp	.auto_fname_end
.auto_have_fname:
	; SI = byte after filename (ws or null). Save & null-terminate.
	mov	al, [si]
	mov	ah, al			; save original byte
	mov	byte [si], 0
	push	si
	push	ax
	mov	si, bx
	call	store_filename
	pop	ax
	pop	si
	mov	[si], ah
	jc	main_loop
	cmp	byte [file_name_set], 0
	je	main_loop

	; Copy the remaining tail (just the args) into target PSP:80.
	; SI points at the byte after the filename; walk past leading ws,
	; then copy chars into target_seg:0x81, count into target_seg:0x80,
	; and put a 0x0D terminator at the end.
	call	skip_delims
	push	ds
	push	es
	mov	ax, [target_seg]
	mov	es, ax
	mov	di, 0x81
	xor	cx, cx			; CX = length
.auto_args_copy:
	mov	al, [si]
	or	al, al
	je	.auto_args_done
	mov	[es:di], al
	inc	si
	inc	di
	inc	cx
	cmp	cx, 126
	jb	.auto_args_copy
.auto_args_done:
	mov	byte [es:di], 0x0D
	mov	[es:0x80], cl
	pop	es
	pop	ds

	call	rebuild_target_fcbs

	jmp	cmd_load.load_have_name

start_fail:
	mov	si, msg_no_memory
	call	print_str
	mov	ax, 0x4C01
	int	0x21

main_loop:
	mov	al, '-'
	call	putc

	call	read_command
	mov	si, cmd_text
	call	skip_delims
	cmp	byte [si], 0
	je	main_loop

	mov	al, [si]
	call	to_upper
	cmp	al, '?'
	je	cmd_help
	cmp	al, 'Q'
	je	cmd_quit
	cmp	al, 'A'
	je	cmd_assemble
	cmp	al, 'B'
	je	cmd_b_group
	cmp	al, 'C'
	je	cmd_compare
	cmp	al, 'D'
	je	cmd_dump
	cmp	al, 'E'
	je	cmd_enter
	cmp	al, 'F'
	je	cmd_fill
	cmp	al, 'G'
	je	cmd_go
	cmp	al, 'H'
	je	cmd_hexmath
	cmp	al, 'I'
	je	cmd_inport
	cmp	al, 'L'
	je	cmd_load
	cmp	al, 'M'
	je	cmd_move
	cmp	al, 'N'
	je	cmd_name
	cmp	al, 'O'
	je	cmd_outport
	cmp	al, 'P'
	je	cmd_proceed
	cmp	al, 'S'
	je	cmd_search
	cmp	al, 'R'
	je	cmd_regs
	cmp	al, 'T'
	je	cmd_trace
	cmp	al, 'U'
	je	cmd_unassemble
	cmp	al, 'W'
	je	cmd_write
	jmp	cmd_error

cmd_help:
	mov	si, msg_help
	call	print_str
	jmp	main_loop

cmd_quit:
	mov	ax, [target_seg]
	or	ax, ax
	jz	.quit_now
	mov	es, ax
	mov	ah, 0x49
	int	0x21
.quit_now:
	mov	ax, 0x4C00
	int	0x21

cmd_name:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.n_just_clear			; bare N clears the name
	; Split filename from args exactly like the startup auto-load path.
	mov	bx, si
.n_fname_end:
	mov	al, [si]
	or	al, al
	je	.n_have_fname
	cmp	al, ' '
	je	.n_have_fname
	cmp	al, 9
	je	.n_have_fname
	inc	si
	jmp	.n_fname_end
.n_have_fname:
	mov	al, [si]
	mov	ah, al
	mov	byte [si], 0
	push	si
	push	ax
	mov	si, bx
	call	store_filename
	pop	ax
	pop	si
	mov	[si], ah
	jc	cmd_error
	cmp	byte [file_name_set], 0
	je	.name_cleared

	; Rebuild target PSP:80 with the args portion so a later L/G run
	; sees the user's arguments instead of whatever was there before.
	call	skip_delims
	push	ds
	push	es
	mov	ax, [target_seg]
	mov	es, ax
	mov	di, 0x81
	xor	cx, cx
.n_args_copy:
	mov	al, [si]
	or	al, al
	je	.n_args_done
	mov	[es:di], al
	inc	si
	inc	di
	inc	cx
	cmp	cx, 126
	jb	.n_args_copy
.n_args_done:
	mov	byte [es:di], 0x0D
	mov	[es:0x80], cl
	pop	es
	pop	ds

	call	rebuild_target_fcbs

	mov	si, msg_name_set
	call	print_str
	mov	si, file_name
	call	print_str
	call	crlf
	jmp	main_loop

.n_just_clear:
	call	store_filename			; clears file_name with empty input
	jc	cmd_error
.name_cleared:
	; Also wipe any args in target PSP:80 and rebuild empty FCBs.
	push	es
	mov	ax, [target_seg]
	mov	es, ax
	mov	byte [es:0x80], 0
	mov	byte [es:0x81], 0x0D
	pop	es
	call	rebuild_target_fcbs
	mov	si, msg_name_cleared
	call	print_str
	jmp	main_loop

cmd_load:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.load_have_name
	; Split filename from args exactly like cmd_name / auto-load, so
	; "L PROG.COM arg1 arg2" sets the target PSP tail and FCBs too.
	mov	bx, si
.l_fname_end:
	mov	al, [si]
	or	al, al
	je	.l_have_fname
	cmp	al, ' '
	je	.l_have_fname
	cmp	al, 9
	je	.l_have_fname
	inc	si
	jmp	.l_fname_end
.l_have_fname:
	mov	al, [si]
	mov	ah, al
	mov	byte [si], 0
	push	si
	push	ax
	mov	si, bx
	call	store_filename
	pop	ax
	pop	si
	mov	[si], ah
	jc	cmd_error

	; Copy args (if any) into target PSP:80 and rebuild FCBs.
	call	skip_delims
	push	ds
	push	es
	mov	ax, [target_seg]
	mov	es, ax
	mov	di, 0x81
	xor	cx, cx
.l_args_copy:
	mov	al, [si]
	or	al, al
	je	.l_args_done
	mov	[es:di], al
	inc	si
	inc	di
	inc	cx
	cmp	cx, 126
	jb	.l_args_copy
.l_args_done:
	mov	byte [es:di], 0x0D
	mov	[es:0x80], cl
	pop	es
	pop	ds
	call	rebuild_target_fcbs

.load_have_name:
	cmp	byte [file_name_set], 0
	je	.no_name
	call	open_named_read
	jc	cmd_file_error
	mov	[file_handle], ax

	call	seek_handle_end
	jc	.load_close_fail
	mov	[file_size], ax
	mov	[file_size_hi], dx		; full 32-bit size (EXEs can have large reloc tables)

	call	seek_handle_start
	jc	.load_close_fail

	; Peek at first 28 bytes to detect MZ/ZM EXE header. Check the full
	; 32-bit size — a file >64K with low word < 28 is still big enough
	; to peek and must not fall through to the COM path.
	cmp	word [file_size_hi], 0
	jne	.peek_header
	cmp	word [file_size], 28
	jb	.load_as_com
.peek_header:
	push	ds
	push	cs
	pop	ds
	mov	bx, [file_handle]
	mov	cx, 28
	mov	dx, exe_header
	mov	ah, 0x3F
	int	0x21
	pop	ds
	jc	.load_close_fail
	cmp	ax, 28				; short peek from a ≥28-byte file = disk
	jne	.load_close_fail		; error; don't misclassify MZ/ZM
	mov	ax, [exe_header]
	cmp	ax, 0x5A4D			; 'MZ'
	je	.load_as_exe
	cmp	ax, 0x4D5A			; 'ZM'
	je	.load_as_exe

.load_as_com:
	; COM: the whole file loads at target_seg:0x100, so it must fit in
	; the segment window (64K minus 256 for the PSP). We can't enforce
	; this pre-EXE-check because EXE files with big headers/reloc tables
	; but sub-64K images are still loadable.
	cmp	word [file_size_hi], 0
	jne	.load_too_big
	cmp	word [file_size], 0xFE00
	ja	.load_too_big
	; Rewind and read whole file at target_seg:0x100 (COM behavior).
	call	seek_handle_start
	jc	.load_close_fail
	push	ds
	mov	bx, [file_handle]
	mov	cx, [file_size]
	mov	dx, 0x0100
	mov	ax, [target_seg]
	mov	ds, ax
	mov	ah, 0x3F
	int	0x21
	pop	ds
	jc	.load_close_fail
	cmp	ax, [file_size]
	jne	.load_close_fail

	call	close_named_handle
	jc	cmd_error

	call	reset_target_frame
	mov	ax, [file_size]
	mov	[target_cx], ax
	mov	word [target_bx], 0x0100
	mov	word [target_dx], 0
	mov	byte [target_loaded], 1

	mov	ax, [target_seg]
	mov	[default_seg], ax
	mov	[last_dump_seg], ax
	mov	word [last_dump_off], 0x0100
	jmp	.load_print_size

; --- EXE load path ---
; Skip the MZ header, load the code portion at target_seg:0x0100 (so it
; appears at load_seg=target_seg+0x10, offset 0 — same linear address).
; Apply each relocation by adding load_seg to the 16-bit word it points at.
; Then set target CS:IP, SS:SP, DS, ES from the header.
.load_as_exe:
	mov	ax, [target_seg]
	add	ax, 0x10			; skip PSP (16 paragraphs)
	mov	[exe_load_seg], ax

	; Header size in bytes = header_paragraphs * 16. A malformed EXE can
	; claim a header bigger than the file — reject rather than let the
	; subtraction underflow and send the loader off into garbage.
	mov	ax, [exe_header + 8]
	or	ax, ax
	jz	.load_close_fail		; header_paragraphs == 0 is invalid
	mov	cl, 4
	; Reject header >= 0x1000 paragraphs (would overflow the 16-bit
	; header_bytes computation into 64K+).
	cmp	ax, 0x1000
	jae	.load_close_fail
	shl	ax, cl
	mov	[exe_hdr_bytes], ax
	; Header must not exceed total file size (32-bit compare).
	cmp	word [file_size_hi], 0
	jne	.hdr_ok				; file >64K → any 16-bit header fits
	cmp	ax, [file_size]
	ja	.load_close_fail
.hdr_ok:

	; Code size = file_size(32-bit) - header_bytes(16-bit)
	mov	ax, [file_size]
	mov	dx, [file_size_hi]
	sub	ax, [exe_hdr_bytes]
	sbb	dx, 0
	; Must fit a 64K segment at target_seg:0x100.
	or	dx, dx
	jnz	.load_too_big
	cmp	ax, 0xFE00
	ja	.load_too_big
	mov	[exe_code_size], ax

	; Seek past header
	mov	bx, [file_handle]
	xor	cx, cx
	mov	dx, [exe_hdr_bytes]
	mov	ax, 0x4200
	int	0x21
	jc	.load_close_fail

	; Read code into target_seg:0x0100. Load BX/CX from DEBUG's DS *before*
	; switching DS to target_seg — otherwise the indirect loads hit
	; target_seg's empty memory and we end up asking AH=3F to read 0 bytes.
	mov	bx, [file_handle]
	mov	cx, [exe_code_size]
	mov	dx, 0x0100
	push	ds
	mov	ax, [target_seg]
	mov	ds, ax
	mov	ah, 0x3F
	int	0x21
	pop	ds
	jc	.load_close_fail
	; Reject short read — a truncated EXE would otherwise half-load.
	cmp	ax, [exe_code_size]
	jne	.load_close_fail

	; Apply relocations (if any)
	mov	ax, [exe_header + 6]		; reloc count
	or	ax, ax
	jz	.exe_reloc_done
	mov	[exe_reloc_count], ax

	; Seek to relocation table
	mov	bx, [file_handle]
	xor	cx, cx
	mov	dx, [exe_header + 24]
	mov	ax, 0x4200
	int	0x21
	jc	.load_close_fail

.exe_reloc_loop:
	push	ds
	push	cs
	pop	ds
	mov	bx, [file_handle]
	mov	cx, 4
	mov	dx, reloc_entry
	mov	ah, 0x3F
	int	0x21
	pop	ds
	jc	.load_close_fail
	cmp	ax, 4				; each reloc entry is exactly 4 bytes
	jne	.load_close_fail

	; reloc_entry[0] = offset, [2] = segment (both relative to load image).
	; Bounds-check against the loaded image before writing — a malformed
	; EXE could otherwise scribble outside the code block. Compute the
	; 32-bit linear offset (reloc_seg*16 + reloc_off), require the high
	; half to be zero (so <64K into the image), and require the 2-byte
	; word write to fit within exe_code_size.
	mov	ax, [reloc_entry + 2]
	mov	cx, 16
	mul	cx				; DX:AX = reloc_seg * 16
	add	ax, [reloc_entry]
	adc	dx, 0
	or	dx, dx
	jne	.load_close_fail
	add	ax, 2				; need offset + 2 <= code_size
	jc	.load_close_fail
	cmp	ax, [exe_code_size]
	ja	.load_close_fail
	sub	ax, 2				; restore offset
	mov	bx, [reloc_entry + 2]
	add	bx, [exe_load_seg]		; actual segment in memory
	push	ds
	mov	ds, bx
	mov	bx, ax
	mov	ax, [exe_load_seg]
	add	[bx], ax			; relocate the word in place
	pop	ds

	dec	word [exe_reloc_count]
	jnz	.exe_reloc_loop

.exe_reloc_done:
	call	close_named_handle
	jc	cmd_error

	; Initialize target state, then override for EXE.
	call	reset_target_frame
	mov	ax, [exe_load_seg]
	add	ax, [exe_header + 22]		; CS = load_seg + initial_cs
	mov	[target_cs], ax
	mov	ax, [exe_header + 20]		; IP = initial_ip
	mov	[target_ip], ax
	mov	ax, [exe_load_seg]
	add	ax, [exe_header + 14]		; SS = load_seg + initial_ss
	mov	[target_ss], ax
	mov	ax, [exe_header + 16]		; SP = initial_sp
	mov	[target_sp], ax
	mov	ax, [target_seg]		; DS/ES = PSP segment
	mov	[target_ds], ax
	mov	[target_es], ax
	mov	ax, [exe_code_size]
	mov	[target_cx], ax
	mov	word [target_bx], 0
	mov	word [target_dx], 0
	mov	byte [target_loaded], 1

	mov	ax, [target_cs]
	mov	[default_seg], ax
	mov	[last_dump_seg], ax
	mov	ax, [target_ip]
	mov	[last_dump_off], ax
	mov	ax, [exe_code_size]
	mov	[file_size], ax			; show code size, not total file

.load_print_size:

	mov	si, msg_loaded
	call	print_str
	mov	ax, [file_size]
	call	print_hex16
	call	crlf
	jmp	main_loop

.load_too_big:
	call	close_named_handle
	mov	si, msg_too_big
	call	print_str
	jmp	main_loop

.load_close_fail:
	pushf
	call	close_named_handle
	popf
	jc	cmd_file_error
	jmp	cmd_file_error

.no_name:
	mov	si, msg_no_name
	call	print_str
	jmp	main_loop

cmd_write:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.w_defaults
	; Parse address.
	call	parse_addr
	jc	cmd_error
	mov	[w_seg], dx
	mov	[w_off], ax
	call	skip_delims
	cmp	byte [si], 0
	je	.w_len_from_cx
	; Parse explicit length.
	call	parse_hex_word
	jc	cmd_error
	mov	[w_len], ax
	jmp	.w_do

.w_len_from_cx:
	mov	ax, [target_cx]
	mov	[w_len], ax
	jmp	.w_do

.w_defaults:
	; "W" alone: DS:BX for len CX (classic DOS DEBUG semantics). This
	; supports the E/A + R BX + R CX + W workflow for building files
	; from scratch. L populates target_bx/cx with its own defaults, but
	; for EXE-loaded targets DS:BX points at the PSP — use explicit
	; "W CS:0 <len>" to write the loaded code back out.
	mov	ax, [target_ds]
	mov	[w_seg], ax
	mov	ax, [target_bx]
	mov	[w_off], ax
	mov	ax, [target_cx]
	mov	[w_len], ax

.w_do:
	cmp	byte [file_name_set], 0
	je	print_no_name

	push	ds
	push	cs
	pop	ds
	mov	dx, file_name
	xor	cx, cx
	mov	ah, 0x3C
	int	0x21
	pop	ds
	jc	cmd_file_error
	mov	[file_handle], ax

	mov	bx, [file_handle]
	mov	cx, [w_len]
	mov	dx, [w_off]
	push	ds
	mov	ax, [w_seg]
	mov	ds, ax
	mov	ah, 0x40
	int	0x21
	pop	ds
	jc	.write_close_fail
	; Short write (AX < requested) = disk full / out of space.
	cmp	ax, [w_len]
	jne	.write_close_fail
	mov	[file_size], ax

	call	close_named_handle
	jc	cmd_error
	mov	si, msg_written
	call	print_str
	mov	ax, [file_size]
	call	print_hex16
	call	crlf
	jmp	main_loop

.write_close_fail:
	pushf
	call	close_named_handle
	popf
	jc	cmd_file_error
	jmp	cmd_file_error

cmd_go:
	mov	byte [run_mode], MODE_GO
	jmp	cmd_run_common

cmd_trace:
	mov	byte [run_mode], MODE_TRACE
	jmp	cmd_run_common

cmd_proceed:
	mov	byte [run_mode], MODE_PROCEED
	jmp	cmd_run_common

cmd_run_common:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.run_check_term
	call	parse_addr
	jc	cmd_error
	mov	[target_ip], ax
	mov	[target_cs], dx
	; An explicit address means the user wants to start fresh — clear
	; the terminated flag so the guard below accepts the run.
	mov	byte [target_terminated], 0
	jmp	.run_ready
.run_check_term:
	; Bare G/T/P without an address: refuse to resume a terminated target.
	; IP is sitting past the INT 20/4C that terminated it, so continuing
	; would run into whatever follows in memory. The user can reload
	; (L) or set an explicit address on the run command to start over.
	cmp	byte [target_terminated], 0
	je	.run_ready
	mov	si, msg_terminated
	call	print_str
	jmp	main_loop
.run_ready:
	call	prepare_run
	jc	cmd_error
	mov	byte [bp_skip_pending], 0
	; If G (free run) and target_ip sits on an active BP, the BP won't be
	; installed this pass (bp_install skips current IP). Turn on TF so we
	; single-step one instruction, and set bp_skip_pending so int1_handler
	; re-installs the skipped BP and lets the target keep running.
	cmp	byte [run_mode], MODE_GO
	jne	.run_not_go
	call	bp_at_current_ip
	jc	.run_not_go
	mov	byte [bp_skip_pending], 1
	mov	ax, [target_flags]
	or	ax, 0x0100
	mov	[target_flags], ax
.run_not_go:
	call	bp_install
	cmp	byte [run_mode], MODE_PROCEED
	jne	.run_do
	call	setup_proceed_break
.run_do:
	jmp	run_target

cmd_regs:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.show_all

	; "R F" alone (not "RFL") enters flag-edit mode.
	mov	al, [si]
	call	to_upper
	cmp	al, 'F'
	jne	.parse_reg_ptr_call
	mov	al, [si + 1]
	or	al, al
	jz	.flag_edit
	cmp	al, ' '
	je	.flag_edit
	cmp	al, 9
	je	.flag_edit
	; Not "F<ws>" — fall through (probably FL)
.parse_reg_ptr_call:
	mov	[reg_name_ptr], si
	call	parse_reg_ptr
	jc	cmd_error
	mov	[reg_ptr], bx
	mov	[reg_size], al
	call	skip_delims
	cmp	byte [si], 0
	je	.edit_one
	call	parse_hex_word
	jc	cmd_error
	mov	bx, [reg_ptr]
	cmp	byte [reg_size], 1
	jne	.cr_store_word
	; Byte register: high byte of parsed value must be 0.
	or	ah, ah
	jne	cmd_error
	mov	[bx], al
	jmp	.cr_done
.cr_store_word:
	mov	[bx], ax
.cr_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

.show_all:
	call	show_target_regs
	jmp	main_loop

.edit_one:
	mov	bx, [reg_name_ptr]
	mov	al, [bx]
	call	to_upper
	call	putc
	mov	al, [bx + 1]
	call	to_upper
	call	putc
	mov	al, ' '
	call	putc
	mov	bx, [reg_ptr]
	cmp	byte [reg_size], 1
	jne	.cr_edit_word
	mov	al, [bx]
	call	print_hex8
	jmp	.cr_edit_prompt
.cr_edit_word:
	mov	ax, [bx]
	call	print_hex16
.cr_edit_prompt:
	call	crlf
	mov	al, ':'
	call	putc
	call	read_command
	mov	si, cmd_text
	call	skip_delims
	cmp	byte [si], 0
	je	main_loop
	call	parse_hex_word
	jc	cmd_error
	mov	bx, [reg_ptr]
	cmp	byte [reg_size], 1
	jne	.cr_edit_store_word
	or	ah, ah
	jne	cmd_error
	mov	[bx], al
	jmp	.cr_edit_done
.cr_edit_store_word:
	mov	[bx], ax
.cr_edit_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error
	call	show_target_regs
	jmp	main_loop

.flag_edit:
	call	do_flag_edit
	call	show_target_regs
	jmp	main_loop

cmd_assemble:
	inc	si
	call	skip_delims
	call	parse_addr
	jc	cmd_error
	mov	[work_seg], dx
	mov	[work_start], ax
	call	skip_delims
	cmp	byte [si], 0
	je	.a_interactive
	; One-shot: "A addr <instruction>"
	call	assemble_line
	jc	cmd_error
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	ax, [work_start]
	mov	[last_dump_off], ax
	jmp	main_loop

; --- Interactive assemble mode ---
; Prompt with "SEG:OFF _" each line. Empty line exits. On failure the
; error is shown and the same address is re-prompted. On success the
; address advances (assemble_line has updated work_start).
.a_interactive:
.ai_prompt:
	mov	ax, [work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [work_start]
	call	print_hex16
	mov	al, ' '
	call	putc
	call	read_command
	mov	si, cmd_text
	call	skip_delims
	cmp	byte [si], 0
	je	.ai_done
	call	assemble_line
	jc	.ai_err
	jmp	.ai_prompt
.ai_err:
	mov	si, msg_error
	call	print_str
	jmp	.ai_prompt
.ai_done:
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	ax, [work_start]
	mov	[last_dump_off], ax
	jmp	main_loop

cmd_unassemble:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	jne	.u_have_addr
	; "U" alone: continue 32 bytes from last_dump_off (or target IP on first call)
	mov	ax, [last_dump_seg]
	mov	[work_seg], ax
	mov	ax, [last_dump_off]
	mov	[work_start], ax
	add	ax, 0x1F
	mov	[u_end_off], ax
	jmp	.u_run

.u_have_addr:
	call	parse_addr
	jc	cmd_error
	mov	[work_seg], dx
	mov	[work_start], ax
	call	skip_delims
	cmp	byte [si], 0
	je	.u_default_end
	; "L count" syntax: u_end_off = work_start + count - 1
	mov	al, [si]
	call	to_upper
	cmp	al, 'L'
	jne	.u_end_addr
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	or	ax, ax
	jz	cmd_error			; L 0 invalid
	dec	ax
	add	ax, [work_start]
	mov	[u_end_off], ax
	jmp	.u_run
.u_end_addr:
	; Parse second argument as inclusive end address (classic DEBUG syntax).
	call	parse_hex_word
	jc	cmd_error
	mov	[u_end_off], ax
	jmp	.u_run

.u_default_end:
	mov	ax, [work_start]
	add	ax, 0x1F			; ~32 bytes default window
	mov	[u_end_off], ax

.u_run:
	mov	ax, [work_start]
	cmp	ax, [u_end_off]
	ja	.u_done
	call	disasm_current
	mov	[work_start], ax
	jmp	.u_run
.u_done:
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	ax, [work_start]
	mov	[last_dump_off], ax
	jmp	main_loop

show_target_regs:
	call	crlf

	mov	si, msg_ax
	call	print_str
	mov	ax, [target_ax]
	call	print_hex16

	mov	si, msg_bx
	call	print_str
	mov	ax, [target_bx]
	call	print_hex16

	mov	si, msg_cx
	call	print_str
	mov	ax, [target_cx]
	call	print_hex16

	mov	si, msg_dx
	call	print_str
	mov	ax, [target_dx]
	call	print_hex16
	call	crlf

	mov	si, msg_si
	call	print_str
	mov	ax, [target_si]
	call	print_hex16

	mov	si, msg_di
	call	print_str
	mov	ax, [target_di]
	call	print_hex16

	mov	si, msg_bp
	call	print_str
	mov	ax, [target_bp]
	call	print_hex16

	mov	si, msg_sp
	call	print_str
	mov	ax, [target_sp]
	call	print_hex16
	call	crlf

	mov	si, msg_cs
	call	print_str
	mov	ax, [target_cs]
	call	print_hex16

	mov	si, msg_ds
	call	print_str
	mov	ax, [target_ds]
	call	print_hex16

	mov	si, msg_es
	call	print_str
	mov	ax, [target_es]
	call	print_hex16

	mov	si, msg_ss
	call	print_str
	mov	ax, [target_ss]
	call	print_hex16
	call	crlf

	mov	si, msg_ip
	call	print_str
	mov	ax, [target_ip]
	call	print_hex16

	mov	si, msg_fl
	call	print_str
	mov	ax, [target_flags]
	call	print_hex16
	mov	al, ' '
	call	putc
	mov	al, ' '
	call	putc
	call	print_flags_mnemonic
	call	crlf

	mov	si, msg_def
	call	print_str
	mov	ax, [default_seg]
	call	print_hex16

	mov	si, msg_dump
	call	print_str
	mov	ax, [last_dump_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [last_dump_off]
	call	print_hex16
	call	crlf
	ret

; ============================================================================
; print_flags_mnemonic — print 8 space-separated flag mnemonics for target_flags
; ============================================================================
; Uses the classic DEBUG form: OV/NV DN/UP EI/DI NG/PL ZR/NZ AC/NA PE/PO CY/NC
;
print_flags_mnemonic:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	mov	dx, [target_flags]
	mov	bx, flag_mnem_tbl
	mov	cx, 8
.pfm_loop:
	mov	ax, [bx + 4]		; bit mask
	test	dx, ax
	jz	.pfm_clear
	mov	si, bx			; set mnemonic at bx+0
	jmp	.pfm_print
.pfm_clear:
	lea	si, [bx + 2]		; clear mnemonic at bx+2
.pfm_print:
	mov	al, [si]
	call	putc
	mov	al, [si + 1]
	call	putc
	add	bx, 6
	dec	cx
	jz	.pfm_done
	mov	al, ' '
	call	putc
	jmp	.pfm_loop
.pfm_done:
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; ============================================================================
; do_flag_edit — "R F": show current mnemonics, read input, toggle flags
; ============================================================================
; Each input token is a 2-char mnemonic. Set mnemonics set the flag;
; clear mnemonics clear the flag. Unknown tokens are ignored.
;
do_flag_edit:
	call	print_flags_mnemonic
	mov	al, ' '
	call	putc
	mov	al, '-'
	call	putc
	call	read_command
	mov	si, cmd_text
.fe_tok:
	call	skip_delims
	cmp	byte [si], 0
	je	.fe_done
	; Build uppercased 2-char token in DX (DL=first, DH=second)
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	mov	dh, al
	inc	si
	inc	si
	; Walk flag_mnem_tbl
	push	si
	mov	si, flag_mnem_tbl
	mov	cx, 8
.fe_walk:
	mov	ax, [si]		; SET mnemonic (little-endian 2 bytes)
	cmp	ax, dx
	je	.fe_set
	mov	ax, [si + 2]		; CLEAR mnemonic
	cmp	ax, dx
	je	.fe_clear
	add	si, 6
	loop	.fe_walk
	pop	si
	jmp	.fe_tok
.fe_set:
	mov	ax, [si + 4]
	or	[target_flags], ax
	pop	si
	jmp	.fe_tok
.fe_clear:
	mov	ax, [si + 4]
	not	ax
	and	[target_flags], ax
	pop	si
	jmp	.fe_tok
.fe_done:
	ret

; Flag mnemonic table — 8 entries × 6 bytes each.
; Layout per entry: [0..1] SET mnemonic, [2..3] CLEAR mnemonic, [4..5] bit mask
flag_mnem_tbl:
	db	'OV'
	db	'NV'
	dw	0x0800		; OF
	db	'DN'
	db	'UP'
	dw	0x0400		; DF
	db	'EI'
	db	'DI'
	dw	0x0200		; IF
	db	'NG'
	db	'PL'
	dw	0x0080		; SF
	db	'ZR'
	db	'NZ'
	dw	0x0040		; ZF
	db	'AC'
	db	'NA'
	dw	0x0010		; AF
	db	'PE'
	db	'PO'
	dw	0x0004		; PF
	db	'CY'
	db	'NC'
	dw	0x0001		; CF

cmd_compare:
	inc	si
	call	parse_range
	jc	cmd_error
	call	skip_delims
	call	parse_addr
	jc	cmd_error
	mov	[dest_seg], dx
	mov	[dest_off], ax
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	mov	ax, [work_end]
	sub	ax, [work_start]
	inc	ax
	mov	byte [diff_found], 0
	push	ds
	push	es
	mov	ax, [cs:work_seg]
	mov	ds, ax
	mov	ax, [cs:dest_seg]
	mov	es, ax
	mov	si, [cs:work_start]
	mov	di, [cs:dest_off]
	or	ax, ax
	jnz	.compare_sized

.compare_full_loop:
	mov	al, [ds:si]
	cmp	al, [es:di]
	je	.compare_full_next
	mov	byte [cs:diff_found], 1
	mov	[cs:compare_src_byte], al
	mov	al, [es:di]
	mov	[cs:compare_dst_byte], al

	mov	ax, [cs:work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, si
	call	print_hex16
	mov	al, ' '
	call	putc
	mov	al, [cs:compare_src_byte]
	call	print_hex8
	mov	al, ' '
	call	putc
	mov	al, [cs:compare_dst_byte]
	call	print_hex8
	call	crlf

.compare_full_next:
	inc	si
	inc	di
	jnz	.compare_full_loop
	jmp	.compare_done

.compare_sized:
	mov	cx, ax

.compare_loop:
	mov	al, [ds:si]
	cmp	al, [es:di]
	je	.compare_next
	mov	byte [cs:diff_found], 1
	mov	[cs:compare_src_byte], al
	mov	al, [es:di]
	mov	[cs:compare_dst_byte], al

	mov	ax, [cs:work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, si
	call	print_hex16
	mov	al, ' '
	call	putc
	mov	al, [cs:compare_src_byte]
	call	print_hex8
	mov	al, ' '
	call	putc
	mov	al, [cs:compare_dst_byte]
	call	print_hex8
	call	crlf

.compare_next:
	inc	si
	inc	di
	loop	.compare_loop

.compare_done:
	pop	es
	pop	ds
	cmp	byte [diff_found], 0
	jne	main_loop
	mov	si, msg_no_diff
	call	print_str
	jmp	main_loop

cmd_dump:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	je	.dump_use_last

	call	parse_addr
	jc	cmd_error
	mov	[work_seg], dx
	mov	[work_start], ax
	call	skip_delims
	cmp	byte [si], 0
	je	.dump_default_end

	; "L count" syntax: work_end = work_start + count - 1
	mov	al, [si]
	call	to_upper
	cmp	al, 'L'
	jne	.dump_end_addr
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	or	ax, ax
	jz	cmd_error
	dec	ax
	add	ax, [work_start]
	mov	[work_end], ax
	jmp	.dump_do
.dump_end_addr:
	call	parse_addr
	jc	cmd_error
	cmp	dx, [work_seg]
	jne	cmd_bad_range
	mov	[work_end], ax
	mov	ax, [work_start]
	cmp	ax, [work_end]
	ja	cmd_bad_range
	jmp	.dump_do

.dump_use_last:
	mov	ax, [last_dump_seg]
	mov	[work_seg], ax
	mov	ax, [last_dump_off]
	mov	[work_start], ax

.dump_default_end:
	mov	ax, [work_start]
	add	ax, DUMP_BYTES - 1
	jc	.dump_cap_end
	mov	[work_end], ax
	jmp	.dump_do

.dump_cap_end:
	mov	word [work_end], 0xFFFF

.dump_do:
	call	dump_range
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	ax, [work_end]
	inc	ax
	mov	[last_dump_off], ax
	jmp	main_loop

cmd_enter:
	inc	si
	call	skip_delims
	call	parse_addr
	jc	cmd_error
	mov	[work_seg], dx
	mov	[work_start], ax
	call	skip_delims

	push	es
	mov	ax, [work_seg]
	mov	es, ax
	mov	di, [work_start]

	cmp	byte [si], 0
	je	.enter_interactive	; no bytes on line → interactive mode

.enter_loop:
	call	parse_hex_byte
	jc	.enter_fail
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.enter_loop

	pop	es
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	[last_dump_off], di
	jmp	main_loop

.enter_fail:
	pop	es
	jmp	cmd_error

; --- Interactive enter mode ---
; At each prompt, print "SEG:OFF OLD." and read one line.
;   empty line         → exit
;   '-'                → back up one byte (not below the starting address)
;   hex byte (1-2 chr) → store and advance
;   anything else      → skip (advance without writing)
.enter_interactive:
.ei_prompt:
	mov	ax, [work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, di
	call	print_hex16
	mov	al, ' '
	call	putc
	mov	al, [es:di]
	call	print_hex8
	mov	al, '.'
	call	putc

	call	read_command
	mov	si, cmd_text
	call	skip_delims
	cmp	byte [si], 0
	je	.ei_done
	cmp	byte [si], '-'
	je	.ei_back
	call	parse_hex_byte
	jc	.ei_advance		; not a byte → skip forward
	mov	[es:di], al
.ei_advance:
	inc	di
	jmp	.ei_prompt
.ei_back:
	cmp	di, [work_start]
	jbe	.ei_prompt
	dec	di
	jmp	.ei_prompt
.ei_done:
	pop	es
	mov	ax, [work_seg]
	mov	[last_dump_seg], ax
	mov	[last_dump_off], di
	jmp	main_loop

cmd_fill:
	inc	si
	call	parse_range
	jc	cmd_error
	call	skip_delims
	call	parse_hex_byte
	jc	cmd_error
	mov	[fill_byte], al
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	mov	ax, [work_end]
	sub	ax, [work_start]
	inc	ax
	push	es
	mov	ax, [work_seg]
	mov	es, ax
	mov	di, [work_start]
	mov	al, [fill_byte]
	or	ax, ax
	jnz	.fill_sized
	mov	cx, 0x8000
	rep	stosb
	mov	cx, 0x8000
	rep	stosb
	pop	es
	jmp	main_loop

.fill_sized:
	mov	cx, ax
	rep	stosb
	pop	es
	jmp	main_loop

cmd_hexmath:
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	mov	[math_left], ax
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	mov	[math_right], ax
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	mov	ax, [math_left]
	add	ax, [math_right]
	call	print_hex16
	mov	al, ' '
	call	putc
	mov	ax, [math_left]
	sub	ax, [math_right]
	call	print_hex16
	call	crlf
	jmp	main_loop

cmd_inport:
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	mov	dx, ax
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	in	al, dx
	call	print_hex8
	call	crlf
	jmp	main_loop

cmd_move:
	inc	si
	call	parse_range
	jc	cmd_error
	call	skip_delims
	call	parse_addr
	jc	cmd_error
	mov	[dest_seg], dx
	mov	[dest_off], ax
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	mov	ax, [work_end]
	sub	ax, [work_start]
	inc	ax
	mov	[move_len], ax

	; Decide forward vs backward copy before switching DS.
	mov	byte [copy_backward], 0
	mov	ax, [work_seg]
	cmp	ax, [dest_seg]
	jne	.move_do
	mov	ax, [dest_off]
	cmp	ax, [work_start]
	jbe	.move_do
	cmp	ax, [work_end]
	ja	.move_do
	mov	byte [copy_backward], 1

.move_do:
	push	ds
	push	es
	mov	ax, [cs:work_seg]
	mov	ds, ax
	mov	ax, [cs:dest_seg]
	mov	es, ax
	mov	cx, [cs:move_len]
	mov	si, [cs:work_start]
	mov	di, [cs:dest_off]
	cmp	byte [cs:copy_backward], 0
	je	.move_forward
	or	cx, cx
	jnz	.move_backward_sized
	std
	mov	si, 0xFFFF
	dec	di
	mov	cx, 0x8000
	rep	movsb
	mov	cx, 0x8000
	rep	movsb
	cld
	jmp	.move_done

.move_backward_sized:
	std
	add	si, cx
	dec	si
	add	di, cx
	dec	di
	rep	movsb
	cld
	jmp	.move_done

.move_forward:
	or	cx, cx
	jnz	.move_forward_sized
	mov	cx, 0x8000
	rep	movsb
	mov	cx, 0x8000
	rep	movsb
	jmp	.move_done

.move_forward_sized:
	rep	movsb

.move_done:
	pop	es
	pop	ds
	jmp	main_loop

cmd_outport:
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	cmd_error
	mov	dx, ax
	call	skip_delims
	call	parse_hex_byte
	jc	cmd_error
	call	skip_delims
	cmp	byte [si], 0
	jne	cmd_error

	out	dx, al
	jmp	main_loop

cmd_search:
	inc	si
	call	parse_range
	jc	cmd_error
	call	skip_delims
	mov	byte [search_len], 0

.search_load_loop:
	cmp	byte [si], 0
	je	.search_loaded
	mov	al, [search_len]
	cmp	al, SEARCH_MAX
	jae	cmd_error
	call	parse_hex_byte
	jc	cmd_error
	xor	bx, bx
	mov	bl, [search_len]
	mov	[search_bytes + bx], al
	inc	byte [search_len]
	call	skip_delims
	jmp	.search_load_loop

.search_loaded:
	cmp	byte [search_len], 0
	je	cmd_error

	mov	ax, [work_end]
	sub	ax, [work_start]
	inc	ax
	xor	bx, bx
	mov	bl, [search_len]
	or	ax, ax
	jz	.search_full_range
	cmp	ax, bx
	jb	.search_not_found

	mov	ax, [work_end]
	sub	ax, bx
	inc	ax
	jmp	.search_have_max

.search_full_range:
	xor	ax, ax
	sub	ax, bx

.search_have_max:
	mov	[max_start], ax

	push	es
	mov	ax, [work_seg]
	mov	es, ax
	mov	bx, [work_start]
	mov	byte [found_any], 0

.search_next_pos:
	cmp	bx, [max_start]
	ja	.search_done
	push	bx
	mov	di, bx
	mov	si, search_bytes
	mov	cl, [search_len]
	xor	ch, ch

.search_cmp_loop:
	mov	al, [es:di]
	cmp	al, [si]
	jne	.search_miss
	inc	di
	inc	si
	dec	cx
	jnz	.search_cmp_loop

	pop	bx
	mov	byte [found_any], 1
	mov	ax, [work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, bx
	call	print_hex16
	call	crlf
	cmp	bx, [max_start]
	je	.search_done
	inc	bx
	jmp	.search_next_pos

.search_miss:
	pop	bx
	cmp	bx, [max_start]
	je	.search_done
	inc	bx
	jmp	.search_next_pos

.search_done:
	pop	es
	cmp	byte [found_any], 0
	je	.search_not_found
	jmp	main_loop

.search_not_found:
	mov	si, msg_not_found
	call	print_str
	jmp	main_loop

cmd_bad_range:
	mov	si, msg_bad_range
	call	print_str
	jmp	main_loop

print_no_name:
	mov	si, msg_no_name
	call	print_str
	jmp	main_loop

cmd_file_error:
	mov	si, msg_file_error
	call	print_str
	jmp	main_loop

cmd_error:
	mov	si, msg_error
	call	print_str
	jmp	main_loop

run_return:
	call	restore_debug_vectors
	call	stop_adjust_ip		; adjusts target_ip if stop was at a planted CC
	call	restore_temp_break
	call	bp_restore
	push	cs
	pop	ds
	push	cs
	pop	es
	cld
	mov	si, msg_stopped
	call	print_str
	call	show_target_regs
	jmp	main_loop

init_target:
	; Grab all available memory so big EXEs (and their BSS requirements
	; from header min_paragraphs) actually fit. Ask for the max first;
	; that's expected to fail with BX = largest free block, and we
	; re-request with that.
	mov	bx, 0xFFFF
	mov	ah, 0x48
	int	0x21
	jnc	.it_got
	or	bx, bx
	jz	.it_fail
	mov	ah, 0x48
	int	0x21
	jc	.it_fail
.it_got:
	mov	[target_seg], ax

	push	ds
	push	es
	mov	bx, ax
	mov	ax, [psp_seg]
	mov	ds, ax
	mov	es, bx
	xor	si, si
	xor	di, di
	mov	cx, 0x80
	rep	movsw
	pop	es
	pop	ds

	; Fix up target PSP fields that must reflect target_seg rather than
	; DEBUG's PSP. MegaDOS's normal exec (see command.asm ~7063) sets:
	;   PSP:00 = CD 20 (INT 20h terminate) — inherited from DEBUG, same
	;   PSP:02 = memory top segment = target_seg + MCB_size + 1
	;   PSP:05 = CD 21 CB (CALL 5 dispatch) — inherited, same
	;   PSP:16 = parent PSP segment (DEBUG is the "parent" here)
	push	ds
	push	es
	; ES = target_seg PSP
	mov	ax, [cs:target_seg]
	mov	es, ax
	; DS = target's MCB (target_seg - 1)
	dec	ax
	mov	ds, ax
	mov	ax, [0x03]			; block size in paragraphs (DS:0x03)
	add	ax, [cs:target_seg]
	inc	ax				; memtop = target_seg + size + 1
	mov	[es:0x02], ax
	; Parent PSP = DEBUG itself so PSP-introspection doesn't leak
	; DEBUG's parent (COMMAND.COM) through to the target.
	mov	ax, [cs:psp_seg]
	mov	[es:0x16], ax
	; Clear command tail: length 0 at PSP:80, CR at PSP:81. Auto-load
	; from the start path may re-populate this with real program args.
	mov	byte [es:0x80], 0
	mov	byte [es:0x81], 0x0D
	pop	es
	pop	ds

	call	reset_target_frame
	call	rebuild_target_fcbs		; default-FCB starting state
	clc
	ret
.it_fail:
	stc
	ret

; ============================================================================
; close_target_handles — Close any user-range handles (5..19) the target
; left open in its JFT. Called from debug_stop_common on a terminate-family
; stop so DEBUG catching INT 20 / AH=00/31/4C doesn't leak handles that DOS
; would normally free on termination.
; Precondition: DOS's current PSP is still the target's (we haven't done
; AH=50 back to DEBUG yet), and we're on DEBUG's own stack.
;
close_target_handles:
	push	ax
	push	bx
	push	es
	mov	es, [cs:target_seg]
	mov	bx, 5				; system handles 0-4 are stdin/out/err/aux/prn
.cth_loop:
	cmp	bx, 20				; matches MegaDOS MAX_HANDLES
	jae	.cth_done
	cmp	byte [es:0x18 + bx], 0xFF
	je	.cth_next
	push	bx
	mov	ah, 0x3E
	int	0x21
	pop	bx
.cth_next:
	inc	bx
	jmp	.cth_loop
.cth_done:
	pop	es
	pop	bx
	pop	ax
	ret

; ============================================================================
; rebuild_target_fcbs — Populate default FCB #1 (PSP:5C) and FCB #2 (PSP:6C)
; by parsing the current command tail at target PSP:81 via DOS AH=29h.
; Matches MegaDOS's normal EXEC behavior (see command.asm ~7173). Used by
; init_target, auto-load, cmd_name's set/clear paths.
;
rebuild_target_fcbs:
	push	ax
	push	si
	push	di
	push	ds
	push	es
	mov	ax, [cs:target_seg]
	mov	ds, ax				; DS = target_seg (source = PSP:81 tail)
	mov	es, ax				; ES = target_seg (dest = FCBs)
	mov	si, 0x81
	mov	di, 0x5C
	mov	ax, 0x2900
	int	0x21
	mov	di, 0x6C			; AH=29 advanced SI past first arg
	mov	ax, 0x2900
	int	0x21
	pop	es
	pop	ds
	pop	di
	pop	si
	pop	ax
	ret

reset_target_frame:
	mov	ax, [target_seg]
	mov	word [target_ax], 0
	mov	word [target_bx], 0x0100
	mov	word [target_cx], 0
	mov	word [target_dx], 0
	mov	word [target_si], 0
	mov	word [target_di], 0
	mov	word [target_bp], 0
	mov	word [target_ip], 0x0100
	mov	word [target_sp], 0xFFFE
	mov	word [target_flags], 0x0202	; bit 1 is reserved-always-1 on 8086
	mov	[target_cs], ax
	mov	[target_ds], ax
	mov	[target_es], ax
	mov	[target_ss], ax
	mov	[default_seg], ax
	mov	[last_dump_seg], ax
	mov	word [last_dump_off], 0x0100
	; Target's DTA defaults to PSP:0080 (normal DOS program default).
	mov	[target_dta_seg], ax
	mov	word [target_dta_off], 0x0080
	; Fresh target: not yet run to termination.
	mov	byte [target_terminated], 0
	call	seed_target_stack
	; Clear user breakpoint table — old BPs from a prior target are no
	; longer valid offsets in this one.
	push	cx
	push	di
	mov	cx, BP_COUNT * BP_SIZE
	mov	di, bp_table
	xor	al, al
	push	es
	push	ds
	pop	es
	rep	stosb
	pop	es
	pop	di
	pop	cx
	ret

seed_target_stack:
	push	es
	mov	ax, [target_ss]
	mov	es, ax
	mov	di, 0xFFFE
	xor	ax, ax
	mov	[es:di], ax
	pop	es
	ret

store_filename:
	mov	di, file_name
	xor	bx, bx
	cmp	byte [si], 0
	je	.sf_clear

.sf_copy:
	mov	al, [si]
	or	al, al
	jz	.sf_done
	cmp	di, file_name + FNAME_MAX
	jae	.sf_skip_store
	mov	[di], al
	cmp	al, ' '
	je	.sf_advance
	cmp	al, 9
	je	.sf_advance
	mov	bx, di
.sf_advance:
	inc	di
.sf_skip_store:
	inc	si
	jmp	.sf_copy

.sf_done:
	or	bx, bx
	jz	.sf_clear
	mov	di, bx
	inc	di
	mov	byte [di], 0
	mov	byte [file_name_set], 1
	clc
	ret

.sf_clear:
	mov	byte [file_name], 0
	mov	byte [file_name_set], 0
	clc
	ret

open_named_read:
	push	ds
	push	cs
	pop	ds
	mov	dx, file_name
	mov	ax, 0x3D00
	int	0x21
	pop	ds
	ret

close_named_handle:
	mov	bx, [file_handle]
	mov	ah, 0x3E
	int	0x21
	ret

seek_handle_start:
	mov	bx, [file_handle]
	xor	cx, cx
	xor	dx, dx
	mov	ax, 0x4200
	int	0x21
	ret

seek_handle_end:
	mov	bx, [file_handle]
	xor	cx, cx
	xor	dx, dx
	mov	ax, 0x4202
	int	0x21
	ret

prepare_run:
	mov	byte [stop_reason], 0
	mov	ax, [target_flags]
	and	ax, 0xFEFF
	cmp	byte [run_mode], MODE_GO
	je	.pr_store
	or	ax, 0x0100
.pr_store:
	mov	[target_flags], ax
	call	install_debug_vectors
	ret

install_debug_vectors:
	mov	ax, 0x3501
	int	0x21
	mov	[old_int1_off], bx
	mov	[old_int1_seg], es
	mov	ax, 0x3503
	int	0x21
	mov	[old_int3_off], bx
	mov	[old_int3_seg], es
	mov	ax, 0x3520
	int	0x21
	mov	[old_int20_off], bx
	mov	[old_int20_seg], es
	mov	ax, 0x3521
	int	0x21
	mov	[old_int21_off], bx
	mov	[old_int21_seg], es

	push	ds
	push	cs
	pop	ds
	mov	dx, int1_handler
	mov	ax, 0x2501
	int	0x21
	mov	dx, int3_handler
	mov	ax, 0x2503
	int	0x21
	mov	dx, int20_handler
	mov	ax, 0x2520
	int	0x21
	mov	dx, int21_handler
	mov	ax, 0x2521
	int	0x21
	pop	ds
	clc
	ret

run_target:
	; Save DEBUG's current DTA and switch to the target's remembered DTA.
	; target_dta_* defaults to target PSP:0080 but is updated on every
	; stop, so a target that has called AH=1A keeps its DTA across
	; breakpoints/single-steps.
	mov	ah, 0x2F
	int	0x21
	mov	[saved_dta_off], bx
	mov	[saved_dta_seg], es
	mov	dx, [target_dta_off]
	mov	ax, [target_dta_seg]
	push	ds
	mov	ds, ax
	mov	ah, 0x1A
	int	0x21
	pop	ds

	; Switch DOS's current PSP to the target's before we hand off control
	; so AH=51/62 and other PSP-tied services see the target's context
	; rather than DEBUG's. DS/ES are still DEBUG's here, which is what
	; the INT 21h AH=50 path expects.
	mov	bx, [target_seg]
	mov	ah, 0x50
	int	0x21

	cli
	mov	[debugger_ss], ss
	mov	[debugger_sp], sp

	mov	bp, [target_bp]
	mov	si, [target_si]
	mov	di, [target_di]
	mov	bx, [target_bx]
	mov	cx, [target_cx]
	mov	dx, [target_dx]

	mov	ax, [target_ss]
	mov	ss, ax
	mov	sp, [target_sp]
	push	word [cs:target_flags]
	push	word [cs:target_cs]
	push	word [cs:target_ip]
	mov	ax, [cs:target_ds]
	mov	ds, ax
	mov	ax, [cs:target_es]
	mov	es, ax
	mov	ax, [cs:target_ax]
	iret

restore_debug_vectors:
	; Must use cs: overrides when reading old_int*_off/_seg because AH=25h
	; expects DS to hold the vector's segment; reading any subsequent variable
	; from DS after that would fetch from the wrong segment.
	push	ds

	mov	dx, [cs:old_int1_off]
	mov	ax, [cs:old_int1_seg]
	mov	ds, ax
	mov	ax, 0x2501
	int	0x21

	mov	dx, [cs:old_int3_off]
	mov	ax, [cs:old_int3_seg]
	mov	ds, ax
	mov	ax, 0x2503
	int	0x21

	mov	dx, [cs:old_int20_off]
	mov	ax, [cs:old_int20_seg]
	mov	ds, ax
	mov	ax, 0x2520
	int	0x21

	mov	dx, [cs:old_int21_off]
	mov	ax, [cs:old_int21_seg]
	mov	ds, ax
	mov	ax, 0x2521
	int	0x21

	pop	ds
	ret

; ============================================================================
; setup_proceed_break — For P (proceed), plant a temp CC after a step-over
; instruction so the target runs through the call/int/loop/rep as a unit.
; For any other opcode, leave TF set and fall back to single-step behavior.
; Must be called after prepare_run (which has already set TF for MODE_PROCEED).
; ============================================================================
setup_proceed_break:
	push	ax
	push	bx
	push	cx
	push	es

	mov	byte [temp_break_active], 0

	mov	ax, [target_cs]
	mov	es, ax
	mov	bx, [target_ip]
	mov	al, [es:bx]

	; Fixed-length step-over opcodes
	cmp	al, 0xE8		; CALL rel16
	je	.sb_len3
	cmp	al, 0x9A		; CALL ptr16:16
	je	.sb_len5
	cmp	al, 0xCD		; INT imm8
	je	.sb_len2
	cmp	al, 0xE0		; LOOPNZ/LOOPNE cb
	je	.sb_len2
	cmp	al, 0xE1		; LOOPZ/LOOPE cb
	je	.sb_len2
	cmp	al, 0xE2		; LOOP cb
	je	.sb_len2
	cmp	al, 0xF2		; REPNE prefix (+1-byte string op)
	je	.sb_len2
	cmp	al, 0xF3		; REP/REPE prefix (+1-byte string op)
	je	.sb_len2
	cmp	al, 0xFF		; group 5: may be CALL near/far via modrm
	je	.sb_ff
	; Not a recognized step-over opcode — fall through to trace
	jmp	.sb_done

.sb_len2:
	mov	cx, 2
	jmp	.sb_install
.sb_len3:
	mov	cx, 3
	jmp	.sb_install
.sb_len5:
	mov	cx, 5
	jmp	.sb_install

.sb_ff:
	; FF /2 = CALL near [modrm], FF /3 = CALL far [modrm]. Others aren't step-over.
	mov	al, [es:bx+1]		; modrm byte
	mov	ah, al
	mov	cl, 3
	shr	ah, cl
	and	ah, 0x07		; reg field
	cmp	ah, 2
	je	.sb_ff_decode
	cmp	ah, 3
	jne	.sb_done
.sb_ff_decode:
	; Compute total length: 1 (opcode) + modrm + addressing-mode bytes
	mov	ah, al
	and	ah, 0xC0		; mod
	and	al, 0x07		; rm
	cmp	ah, 0xC0
	je	.sb_ff2			; mod=11: register form, 2 bytes
	cmp	ah, 0x00
	je	.sb_ff_mod00
	cmp	ah, 0x40
	je	.sb_ff3			; mod=01: +disp8, 3 bytes
	; mod=10: +disp16, 4 bytes
	mov	cx, 4
	jmp	.sb_install
.sb_ff_mod00:
	cmp	al, 6			; mod=00 rm=110 → disp16 direct
	je	.sb_ff4
	mov	cx, 2
	jmp	.sb_install
.sb_ff2:
	mov	cx, 2
	jmp	.sb_install
.sb_ff3:
	mov	cx, 3
	jmp	.sb_install
.sb_ff4:
	mov	cx, 4

.sb_install:
	; Compute break address = target_cs:target_ip + CX
	mov	ax, [target_ip]
	add	ax, cx
	mov	[temp_break_off], ax
	mov	ax, [target_cs]
	mov	[temp_break_seg], ax
	mov	es, ax
	mov	bx, [temp_break_off]
	mov	al, [es:bx]
	mov	[temp_break_orig], al
	mov	byte [es:bx], 0xCC
	mov	byte [temp_break_active], 1
	; Clear TF in target_flags so we run free until the CC fires
	mov	ax, [target_flags]
	and	ax, 0xFEFF
	mov	[target_flags], ax

.sb_done:
	pop	es
	pop	cx
	pop	bx
	pop	ax
	ret

; ============================================================================
; restore_temp_break — Undo setup_proceed_break's patched byte (IP adjust is
; handled by stop_adjust_ip, which covers both P's temp break and user BPs).
; ============================================================================
restore_temp_break:
	cmp	byte [temp_break_active], 0
	je	.rtb_done
	push	ax
	push	bx
	push	es
	mov	ax, [temp_break_seg]
	mov	es, ax
	mov	bx, [temp_break_off]
	mov	al, [temp_break_orig]
	mov	[es:bx], al
	mov	byte [temp_break_active], 0
	pop	es
	pop	bx
	pop	ax
.rtb_done:
	ret

; ============================================================================
; bp_install — patch 0xCC at every active user breakpoint, save original byte
; ============================================================================
; Skips any slot that sits at target_cs:target_ip so the user can G through
; the instruction they're currently stopped on without the BP firing again.
; Sets BP_F_PATCHED in each slot actually written so bp_restore knows which
; slots to undo.
;
bp_install:
	; Initial install (called from cmd_run_common): skip BP at current IP.
	mov	byte [bp_install_force], 0
	jmp	bp_install_impl

; bp_install_all — force-install every active BP, even at target_cs:target_ip.
; Used by int1_handler after the one-instruction single-step so a BP the
; target jumps BACK to fires on the next execution.
bp_install_all:
	mov	byte [bp_install_force], 1
	; fall through

bp_install_impl:
	push	ax
	push	bx
	push	cx
	push	si
	push	es
	mov	cx, BP_COUNT
	mov	si, bp_table
.bpi_loop:
	mov	al, [si + 5]
	test	al, BP_F_ACTIVE
	jz	.bpi_next
	test	al, BP_F_PATCHED
	jnz	.bpi_next
	cmp	byte [bp_install_force], 0
	jne	.bpi_do			; forced install: no skip
	mov	ax, [target_cs]
	cmp	ax, [si]
	jne	.bpi_do
	mov	ax, [target_ip]
	cmp	ax, [si + 2]
	je	.bpi_next
.bpi_do:
	mov	ax, [si]
	mov	es, ax
	mov	bx, [si + 2]
	mov	al, [es:bx]
	mov	[si + 4], al
	mov	byte [es:bx], 0xCC
	or	byte [si + 5], BP_F_PATCHED
.bpi_next:
	add	si, BP_SIZE
	loop	.bpi_loop
	pop	es
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; ============================================================================
; bp_restore — write original byte back at every slot we patched
; ============================================================================
; Only touches slots that bp_install marked BP_F_PATCHED. Clears the flag
; after restore but leaves BP_F_ACTIVE set so the BP re-arms on next G.
;
bp_restore:
	push	ax
	push	bx
	push	cx
	push	si
	push	es
	mov	cx, BP_COUNT
	mov	si, bp_table
.bpr_loop:
	test	byte [si + 5], BP_F_PATCHED
	jz	.bpr_next
	mov	ax, [si]
	mov	es, ax
	mov	bx, [si + 2]
	mov	al, [si + 4]
	mov	[es:bx], al
	and	byte [si + 5], ~BP_F_PATCHED & 0xFF
.bpr_next:
	add	si, BP_SIZE
	loop	.bpr_loop
	pop	es
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; ============================================================================
; bp_at_current_ip — Is there an active BP at target_cs:target_ip?
; ============================================================================
; Output: CF=0 if yes, CF=1 if no. Clobbers nothing.
;
bp_at_current_ip:
	push	ax
	push	bx
	push	cx
	push	si
	mov	cx, BP_COUNT
	mov	si, bp_table
	mov	ax, [target_cs]
	mov	bx, [target_ip]
.bac_loop:
	test	byte [si + 5], BP_F_ACTIVE
	jz	.bac_next
	cmp	ax, [si]
	jne	.bac_next
	cmp	bx, [si + 2]
	jne	.bac_next
	pop	si
	pop	cx
	pop	bx
	pop	ax
	clc
	ret
.bac_next:
	add	si, BP_SIZE
	loop	.bac_loop
	pop	si
	pop	cx
	pop	bx
	pop	ax
	stc
	ret

; ============================================================================
; stop_adjust_ip — If the stop was at a planted INT 3 (P's temp break or a
; user BP), roll target_ip back by 1 so it points at the restored instruction.
; If INT 3 was in user code (CC compiled into the program), leave IP alone.
; ============================================================================
; Assumes bp_restore and restore_temp_break have NOT yet run (uses their
; saved addresses to identify the hit). Caller should invoke this BEFORE
; the restore pair.
;
stop_adjust_ip:
	cmp	byte [stop_reason], STOP_BREAK
	jne	.sai_done
	push	ax
	push	bx
	push	cx
	push	si
	mov	bx, [target_cs]
	mov	ax, [target_ip]
	dec	ax			; AX = address of CC byte
	; Check P's temp break first
	cmp	byte [temp_break_active], 0
	je	.sai_check_user
	cmp	bx, [temp_break_seg]
	jne	.sai_check_user
	cmp	ax, [temp_break_off]
	jne	.sai_check_user
	mov	[target_ip], ax
	jmp	.sai_out
.sai_check_user:
	mov	cx, BP_COUNT
	mov	si, bp_table
.sai_loop:
	test	byte [si + 5], BP_F_PATCHED
	jz	.sai_next
	cmp	bx, [si]
	jne	.sai_next
	cmp	ax, [si + 2]
	jne	.sai_next
	mov	[target_ip], ax
	jmp	.sai_out
.sai_next:
	add	si, BP_SIZE
	loop	.sai_loop
.sai_out:
	pop	si
	pop	cx
	pop	bx
	pop	ax
.sai_done:
	ret

; ============================================================================
; cmd_b_group — dispatch BP / BL / BC subcommands
; ============================================================================
cmd_b_group:
	inc	si			; past 'B'
	mov	al, [si]
	call	to_upper
	cmp	al, 'P'
	je	do_bp
	cmp	al, 'L'
	je	do_bl
	cmp	al, 'C'
	je	do_bc
	jmp	cmd_error

; --- BP seg:off | BP off ---
do_bp:
	inc	si
	call	skip_delims
	call	parse_addr
	jc	cmd_error
	; AX = off, DX = seg
	push	ax
	push	dx
	; Scan for duplicate; remember first free slot
	mov	cx, BP_COUNT
	mov	si, bp_table
	xor	di, di			; DI = free-slot pointer, 0 = none
.dbp_scan:
	test	byte [si + 5], BP_F_ACTIVE
	jnz	.dbp_active
	; Free slot
	or	di, di
	jnz	.dbp_scan_next
	mov	di, si
	jmp	.dbp_scan_next
.dbp_active:
	cmp	dx, [si]
	jne	.dbp_scan_next
	cmp	ax, [si + 2]
	jne	.dbp_scan_next
	; Duplicate
	pop	dx
	pop	ax
	mov	si, msg_bp_dup
	call	print_str
	jmp	main_loop
.dbp_scan_next:
	add	si, BP_SIZE
	loop	.dbp_scan
	pop	dx
	pop	ax
	or	di, di
	jz	.dbp_full
	mov	[di], dx
	mov	[di + 2], ax
	mov	byte [di + 5], BP_F_ACTIVE
	mov	si, msg_bp_set
	call	print_str
	jmp	main_loop
.dbp_full:
	mov	si, msg_bp_full
	call	print_str
	jmp	main_loop

; --- BL (list breakpoints) ---
do_bl:
	inc	si
	mov	cx, BP_COUNT
	mov	si, bp_table
	xor	bx, bx			; index 0..9
	mov	byte [bp_list_any], 0
.dbl_loop:
	test	byte [si + 5], BP_F_ACTIVE
	jz	.dbl_next
	mov	byte [bp_list_any], 1
	push	bx
	push	cx
	push	si
	mov	al, bl
	add	al, '0'
	call	putc
	mov	al, ':'
	call	putc
	mov	al, ' '
	call	putc
	mov	ax, [si]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [si + 2]
	call	print_hex16
	call	crlf
	pop	si
	pop	cx
	pop	bx
.dbl_next:
	inc	bx
	add	si, BP_SIZE
	loop	.dbl_loop
	cmp	byte [bp_list_any], 0
	jne	.dbl_done
	mov	si, msg_bp_none
	call	print_str
.dbl_done:
	jmp	main_loop

; --- BC n | BC * ---
do_bc:
	inc	si
	call	skip_delims
	cmp	byte [si], '*'
	je	.dbc_all
	call	parse_hex_byte
	jc	cmd_error
	cmp	al, BP_COUNT
	jae	cmd_error
	xor	ah, ah
	mov	bl, BP_SIZE
	mul	bl			; AX = idx * BP_SIZE
	mov	si, bp_table
	add	si, ax
	test	byte [si + 5], BP_F_ACTIVE
	jz	.dbc_notset
	mov	byte [si + 5], 0
	mov	si, msg_bp_cleared
	call	print_str
	jmp	main_loop
.dbc_notset:
	mov	si, msg_bp_notset
	call	print_str
	jmp	main_loop
.dbc_all:
	mov	cx, BP_COUNT
	mov	si, bp_table
.dbc_all_loop:
	mov	byte [si + 5], 0
	add	si, BP_SIZE
	loop	.dbc_all_loop
	mov	si, msg_bp_cleared_all
	call	print_str
	jmp	main_loop

int1_handler:
	; If this trap came from a G-mode "single-step past current BP" setup,
	; re-install all BPs (target_ip has now advanced past the one that was
	; skipped), clear TF in the pushed flags, and IRET back to the target.
	; Do NOT stop — the user asked for G, not T.
	cmp	byte [cs:bp_skip_pending], 0
	je	.i1_normal
	push	ax
	push	bx
	push	cx
	push	si
	push	ds
	push	es
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	byte [bp_skip_pending], 0
	call	bp_install_all
	push	bp
	mov	bp, sp
	; Stack from bp: +0 bp, +2 es, +4 ds, +6 si, +8 cx, +10 bx, +12 ax
	;                +14 IP, +16 CS, +18 FLAGS  (pushed by INT)
	and	word [ss:bp + 18], 0xFEFF	; clear TF in target FLAGS
	pop	bp
	pop	es
	pop	ds
	pop	si
	pop	cx
	pop	bx
	pop	ax
	iret
.i1_normal:
	mov	byte [cs:stop_reason], STOP_TRACE
	jmp	debug_stop_common

int3_handler:
	mov	byte [cs:stop_reason], STOP_BREAK
	jmp	debug_stop_common

int20_handler:
	mov	byte [cs:stop_reason], STOP_INT20
	mov	byte [cs:target_terminated], 1
	jmp	debug_stop_common

int21_handler:
	; Catch every terminate-family call so DOS doesn't free/resize the
	; target block behind DEBUG's back.
	;   AH=00  CP/M-style terminate (jumps to the 4Ch path in MegaDOS)
	;   AH=31  terminate & stay resident (resizes + leaves DEBUG control)
	;   AH=4C  terminate with return code
	or	ah, ah
	jz	.i21_stop
	cmp	ah, 0x31
	je	.i21_stop
	cmp	ah, 0x4C
	je	.i21_stop
	jmp	far [cs:old_int21_off]
.i21_stop:
	mov	byte [cs:stop_reason], STOP_INT21
	mov	byte [cs:target_terminated], 1
	jmp	debug_stop_common

debug_stop_common:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	bp
	push	ds
	push	es
	mov	bp, sp
	push	cs
	pop	ds

	mov	ax, [ss:bp + 16]
	mov	[target_ax], ax
	mov	ax, [ss:bp + 14]
	mov	[target_bx], ax
	mov	ax, [ss:bp + 12]
	mov	[target_cx], ax
	mov	ax, [ss:bp + 10]
	mov	[target_dx], ax
	mov	ax, [ss:bp + 8]
	mov	[target_si], ax
	mov	ax, [ss:bp + 6]
	mov	[target_di], ax
	mov	ax, [ss:bp + 4]
	mov	[target_bp], ax
	mov	ax, [ss:bp + 2]
	mov	[target_ds], ax
	mov	ax, [ss:bp + 0]
	mov	[target_es], ax
	mov	ax, ss
	mov	[target_ss], ax
	lea	ax, [bp + 24]
	mov	[target_sp], ax
	mov	ax, [ss:bp + 18]
	mov	[target_ip], ax
	mov	ax, [ss:bp + 20]
	mov	[target_cs], ax
	mov	ax, [ss:bp + 22]
	and	ax, 0xFEFF
	mov	[target_flags], ax

	cli
	mov	ax, [debugger_ss]
	mov	ss, ax
	mov	sp, [debugger_sp]
	push	cs
	pop	ds
	push	cs
	pop	es
	cld
	sti

	; If the target just hit a terminate-family call (INT 20h / AH=00 /
	; 31 / 4C), DOS didn't get to run its own cleanup because we trapped
	; it. Close any handles 5..19 the target left open, before we switch
	; the current PSP back to DEBUG. AH=3E uses the current PSP's JFT
	; for the handle→SFT lookup, so it has to run while target_seg is
	; still current.
	cmp	byte [target_terminated], 0
	je	.no_handle_cleanup
	call	close_target_handles
.no_handle_cleanup:

	; Restore DOS's current PSP to DEBUG's now that the target is paused,
	; so DEBUG's own DOS calls (file I/O, print, etc.) operate on its PSP.
	mov	bx, [psp_seg]
	mov	ah, 0x50
	int	0x21

	; Snapshot the target's current DTA before restoring DEBUG's, so a
	; target that called AH=1A mid-run keeps that DTA on the next G/T/P.
	mov	ah, 0x2F
	int	0x21
	mov	[target_dta_off], bx
	mov	[target_dta_seg], es

	; Restore DEBUG's saved DTA. If the target changed DTA via AH=1A,
	; DEBUG's subsequent FindFirst/FindNext/FCB calls would otherwise
	; inherit the stale target DTA and corrupt its DTA area. Load DX
	; from DEBUG's DS first, then change DS to the saved segment.
	mov	dx, [saved_dta_off]
	mov	ax, [saved_dta_seg]
	push	ds
	mov	ds, ax
	mov	ah, 0x1A
	int	0x21
	pop	ds

	jmp	run_return

; ============================================================================
; Parsing
; ============================================================================
parse_range:
	call	parse_addr
	jc	.pr_fail
	mov	[work_seg], dx
	mov	[work_start], ax
	call	skip_delims
	; "L count" syntax: work_end = work_start + count - 1
	mov	al, [si]
	call	to_upper
	cmp	al, 'L'
	jne	.pr_end_addr
	inc	si
	call	skip_delims
	call	parse_hex_word
	jc	.pr_fail
	or	ax, ax
	jz	.pr_fail			; L 0 invalid
	dec	ax
	add	ax, [work_start]
	mov	[work_end], ax
	clc
	ret
.pr_end_addr:
	call	parse_addr
	jc	.pr_fail
	cmp	dx, [work_seg]
	jne	.pr_fail
	mov	[work_end], ax
	mov	ax, [work_start]
	cmp	ax, [work_end]
	ja	.pr_fail
	clc
	ret
.pr_fail:
	stc
	ret

parse_addr:
	call	parse_hex_word
	jc	.pa_fail
	mov	bx, ax
	cmp	byte [si], ':'
	jne	.pa_no_seg
	inc	si
	call	parse_hex_word
	jc	.pa_fail
	mov	dx, bx
	mov	[default_seg], dx
	clc
	ret
.pa_no_seg:
	mov	ax, bx
	mov	dx, [default_seg]
	clc
	ret
.pa_fail:
	stc
	ret

parse_hex_byte:
	call	parse_hex_word
	jc	.phb_fail
	cmp	ah, 0
	jne	.phb_fail
	clc
	ret
.phb_fail:
	stc
	ret

parse_hex_word:
	push	bx
	push	cx
	xor	bx, bx
	xor	cx, cx

.phw_loop:
	mov	al, [si]
	call	hex_value
	jc	.phw_done
	shl	bx, 1
	shl	bx, 1
	shl	bx, 1
	shl	bx, 1
	xor	ah, ah
	add	bx, ax
	inc	si
	inc	cx
	cmp	cx, 4
	jb	.phw_loop

	; Reject 5+ hex digits.
	mov	al, [si]
	call	hex_value
	jnc	.phw_fail

.phw_done:
	cmp	cx, 0
	je	.phw_fail
	mov	ax, bx
	pop	cx
	pop	bx
	clc
	ret

.phw_fail:
	pop	cx
	pop	bx
	stc
	ret

; parse_reg_ptr — parse a register name at SI
; Output: BX = pointer to target_* storage, AL = 1 (byte) or 2 (word),
;         SI advanced past the name, CF=0 on success.
;         CF=1 on failure.
parse_reg_ptr:
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	mov	dh, al

	cmp	dl, 'A'
	jne	.prp_bx
	cmp	dh, 'X'
	je	.prp_ax_w
	cmp	dh, 'L'
	je	.prp_al_b
	cmp	dh, 'H'
	je	.prp_ah_b
	jmp	.prp_fail
.prp_ax_w:
	add	si, 2
	mov	bx, target_ax
	mov	al, 2
	clc
	ret
.prp_al_b:
	add	si, 2
	mov	bx, target_ax
	mov	al, 1
	clc
	ret
.prp_ah_b:
	add	si, 2
	mov	bx, target_ax + 1
	mov	al, 1
	clc
	ret
.prp_bx:
	cmp	dl, 'B'
	jne	.prp_cx
	cmp	dh, 'X'
	je	.prp_bx_w
	cmp	dh, 'P'
	je	.prp_bp_w
	cmp	dh, 'L'
	je	.prp_bl_b
	cmp	dh, 'H'
	je	.prp_bh_b
	jmp	.prp_fail
.prp_bx_w:
	add	si, 2
	mov	bx, target_bx
	mov	al, 2
	clc
	ret
.prp_bp_w:
	add	si, 2
	mov	bx, target_bp
	mov	al, 2
	clc
	ret
.prp_bl_b:
	add	si, 2
	mov	bx, target_bx
	mov	al, 1
	clc
	ret
.prp_bh_b:
	add	si, 2
	mov	bx, target_bx + 1
	mov	al, 1
	clc
	ret
.prp_cx:
	cmp	dl, 'C'
	jne	.prp_dx
	cmp	dh, 'X'
	je	.prp_cx_w
	cmp	dh, 'S'
	je	.prp_cs_w
	cmp	dh, 'L'
	je	.prp_cl_b
	cmp	dh, 'H'
	je	.prp_ch_b
	jmp	.prp_fail
.prp_cs_w:
	add	si, 2
	mov	bx, target_cs
	mov	al, 2
	clc
	ret
.prp_cx_w:
	add	si, 2
	mov	bx, target_cx
	mov	al, 2
	clc
	ret
.prp_cl_b:
	add	si, 2
	mov	bx, target_cx
	mov	al, 1
	clc
	ret
.prp_ch_b:
	add	si, 2
	mov	bx, target_cx + 1
	mov	al, 1
	clc
	ret
.prp_dx:
	cmp	dl, 'D'
	jne	.prp_es
	cmp	dh, 'X'
	je	.prp_dx_w
	cmp	dh, 'S'
	je	.prp_ds_w
	cmp	dh, 'I'
	je	.prp_di_w
	cmp	dh, 'L'
	je	.prp_dl_b
	cmp	dh, 'H'
	je	.prp_dh_b
	jmp	.prp_fail
.prp_dx_w:
	add	si, 2
	mov	bx, target_dx
	mov	al, 2
	clc
	ret
.prp_dl_b:
	add	si, 2
	mov	bx, target_dx
	mov	al, 1
	clc
	ret
.prp_dh_b:
	add	si, 2
	mov	bx, target_dx + 1
	mov	al, 1
	clc
	ret
.prp_ds_w:
	add	si, 2
	mov	bx, target_ds
	mov	al, 2
	clc
	ret
.prp_di_w:
	add	si, 2
	mov	bx, target_di
	mov	al, 2
	clc
	ret
.prp_es:
	cmp	dl, 'E'
	jne	.prp_fl
	cmp	dh, 'S'
	jne	.prp_fail
	add	si, 2
	mov	bx, target_es
	mov	al, 2
	clc
	ret
.prp_fl:
	cmp	dl, 'F'
	jne	.prp_ip
	cmp	dh, 'L'
	jne	.prp_fail
	add	si, 2
	mov	bx, target_flags
	mov	al, 2
	clc
	ret
.prp_ip:
	cmp	dl, 'I'
	jne	.prp_si
	cmp	dh, 'P'
	jne	.prp_fail
	add	si, 2
	mov	bx, target_ip
	mov	al, 2
	clc
	ret
.prp_si:
	cmp	dl, 'S'
	jne	.prp_fail
	cmp	dh, 'I'
	jne	.prp_sp
	add	si, 2
	mov	bx, target_si
	mov	al, 2
	clc
	ret
.prp_sp:
	cmp	dh, 'P'
	jne	.prp_ss
	add	si, 2
	mov	bx, target_sp
	mov	al, 2
	clc
	ret
.prp_ss:
	cmp	dh, 'S'
	jne	.prp_fail
	add	si, 2
	mov	bx, target_ss
	mov	al, 2
	clc
	ret
.prp_fail:
	stc
	ret

skip_delims:
.sd_loop:
	cmp	byte [si], ' '
	je	.sd_step
	cmp	byte [si], 9
	je	.sd_step
	cmp	byte [si], ','
	je	.sd_step
	ret
.sd_step:
	inc	si
	jmp	.sd_loop

skip_spaces:
.ss_loop:
	cmp	byte [si], ' '
	je	.ss_step
	cmp	byte [si], 9
	je	.ss_step
	ret
.ss_step:
	inc	si
	jmp	.ss_loop

hex_value:
	call	to_upper
	cmp	al, '0'
	jb	.hv_fail
	cmp	al, '9'
	jbe	.hv_num
	cmp	al, 'A'
	jb	.hv_fail
	cmp	al, 'F'
	ja	.hv_fail
	sub	al, 'A' - 10
	clc
	ret
.hv_num:
	sub	al, '0'
	clc
	ret
.hv_fail:
	stc
	ret

to_upper:
	cmp	al, 'a'
	jb	.tu_done
	cmp	al, 'z'
	ja	.tu_done
	sub	al, 0x20
.tu_done:
	ret

read_command:
	mov	dx, cmd_buffer
	mov	ah, 0x0A
	int	0x21
	xor	bx, bx
	mov	bl, [cmd_buffer + 1]
	mov	byte [cmd_text + bx], 0
	ret

; ============================================================================
; Dump / output helpers
; ============================================================================
dump_range:
	push	es
	mov	ax, [work_seg]
	mov	es, ax
	mov	ax, [work_start]
	and	ax, 0xFFF0
	mov	[line_off], ax

.dr_line_loop:
	mov	ax, [line_off]
	cmp	ax, [work_end]
	ja	.dr_done

	mov	ax, [work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [line_off]
	call	print_hex16
	mov	al, ' '
	call	putc

	mov	bx, [line_off]
	mov	cx, LINE_BYTES
.dr_hex_loop:
	mov	al, ' '
	call	putc
	mov	ax, bx
	cmp	ax, [work_start]
	jb	.dr_hex_blank
	cmp	ax, [work_end]
	ja	.dr_hex_blank
	mov	al, [es:bx]
	call	print_hex8
	jmp	.dr_hex_next
.dr_hex_blank:
	mov	al, ' '
	call	putc
	mov	al, ' '
	call	putc
.dr_hex_next:
	inc	bx
	loop	.dr_hex_loop

	call	crlf
	add	word [line_off], LINE_BYTES
	jc	.dr_done
	jmp	.dr_line_loop

.dr_done:
	pop	es
	ret

print_str:
	lodsb
	or	al, al
	jz	.ps_done
	call	putc
	jmp	print_str
.ps_done:
	ret

crlf:
	mov	al, 0x0D
	call	putc
	mov	al, 0x0A
	call	putc
	ret

putc:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	ds
	push	es
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	es
	pop	ds
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

print_hex16:
	push	ax
	mov	al, ah
	call	print_hex8
	pop	ax
	call	print_hex8
	ret

print_hex8:
	push	ax
	push	cx
	mov	ah, al
	mov	cl, 4
	shr	al, cl
	call	print_hex_nibble
	mov	al, ah
	and	al, 0x0F
	call	print_hex_nibble
	pop	cx
	pop	ax
	ret

print_hex_nibble:
	and	al, 0x0F
	cmp	al, 9
	jbe	.phn_num
	add	al, 'A' - 10
	jmp	putc
.phn_num:
	add	al, '0'
	jmp	putc

; ============================================================================
; Assembly / disassembly helpers
; ============================================================================
disasm_current:
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	es

	mov	ax, [work_seg]
	mov	es, ax
	mov	bx, [work_start]

	mov	ax, [work_seg]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, bx
	call	print_hex16
	mov	al, ' '
	call	putc

	mov	byte [disasm_seg_override], 0
	mov	byte [disasm_rep_prefix], 0
	mov	cx, 4				; consume up to 4 prefix bytes
.du_pfx_loop:
	mov	al, [es:bx]
	cmp	al, 0x26
	je	.du_pfx_seg
	cmp	al, 0x2E
	je	.du_pfx_seg
	cmp	al, 0x36
	je	.du_pfx_seg
	cmp	al, 0x3E
	je	.du_pfx_seg
	cmp	al, 0xF0
	je	.du_pfx_lockrep
	cmp	al, 0xF2
	je	.du_pfx_lockrep
	cmp	al, 0xF3
	je	.du_pfx_lockrep
	jmp	.du_pfx_done
.du_pfx_seg:
	mov	[disasm_seg_override], al
	inc	bx
	loop	.du_pfx_loop
	jmp	.du_pfx_done
.du_pfx_lockrep:
	mov	[disasm_rep_prefix], al
	inc	bx
	loop	.du_pfx_loop
.du_pfx_done:
	; Print LOCK/REP/REPNE mnemonic (with trailing space) if present
	mov	al, [disasm_rep_prefix]
	or	al, al
	jz	.du_no_rep_pfx
	cmp	al, 0xF0
	je	.du_print_lock
	cmp	al, 0xF2
	je	.du_print_repne
	mov	si, str_rep
	jmp	.du_print_pfx
.du_print_lock:
	mov	si, str_lock
	jmp	.du_print_pfx
.du_print_repne:
	mov	si, str_repne
.du_print_pfx:
	call	print_str
	mov	al, ' '
	call	putc
.du_no_rep_pfx:

	mov	al, [es:bx]
	mov	[opcode_byte], al
	cmp	al, 0x90
	je	.du_nop
	cmp	al, 0xCC
	je	.du_int3
	cmp	al, 0xC3
	je	.du_ret
	cmp	al, 0xCB
	je	.du_retf
	cmp	al, 0xCF
	je	.du_iret
	cmp	al, 0xCD
	je	.du_int
	cmp	al, 0xEB
	je	.du_jmp_short
	cmp	al, 0xE9
	je	.du_jmp_near
	cmp	al, 0xE8
	je	.du_call_near
	cmp	al, 0xEA
	je	.du_jmp_far
	cmp	al, 0x9A
	je	.du_call_far
	cmp	al, 0x70
	jb	.du_after_jcc
	cmp	al, 0x7F
	jbe	.du_jcc_short
.du_after_jcc:
	cmp	al, 0xE0
	jb	.du_after_loop_jcxz
	cmp	al, 0xE3
	jbe	.du_loop_short
.du_after_loop_jcxz:
	cmp	al, 0x06
	je	.du_push_seg
	cmp	al, 0x0E
	je	.du_push_seg
	cmp	al, 0x16
	je	.du_push_seg
	cmp	al, 0x1E
	je	.du_push_seg
	cmp	al, 0x07
	je	.du_pop_seg
	cmp	al, 0x17
	je	.du_pop_seg
	cmp	al, 0x1F
	je	.du_pop_seg
	cmp	al, 0x27
	je	.du_daa
	cmp	al, 0x2F
	je	.du_das
	cmp	al, 0x37
	je	.du_aaa
	cmp	al, 0x3F
	je	.du_aas
	cmp	al, 0x98
	je	.du_cbw
	cmp	al, 0x99
	je	.du_cwd
	cmp	al, 0x9B
	je	.du_wait
	cmp	al, 0x9C
	je	.du_pushf
	cmp	al, 0x9D
	je	.du_popf
	cmp	al, 0x9E
	je	.du_sahf
	cmp	al, 0x9F
	je	.du_lahf
	; A4-A7 = MOVS/CMPS, AA-AF = STOS/LODS/SCAS. A8/A9 are TEST acc,imm
	; (handled later) and must NOT fall into the string-op range.
	cmp	al, 0xA4
	jb	.du_after_string_ops
	cmp	al, 0xA7
	jbe	.du_string_op
	cmp	al, 0xAA
	jb	.du_after_string_ops
	cmp	al, 0xAF
	jbe	.du_string_op
.du_after_string_ops:
	cmp	al, 0xCE
	je	.du_into
	cmp	al, 0xC2
	je	.du_ret_imm
	cmp	al, 0xCA
	je	.du_retf_imm
	cmp	al, 0xD4
	je	.du_aam
	cmp	al, 0xD5
	je	.du_aad
	cmp	al, 0xE4
	jb	.du_after_io
	cmp	al, 0xE7
	jbe	.du_inout_imm
	cmp	al, 0xEC
	jb	.du_after_io
	cmp	al, 0xEF
	jbe	.du_inout_dx
.du_after_io:
	cmp	al, 0xF0
	je	.du_lock
	cmp	al, 0xF2
	je	.du_repne
	cmp	al, 0xF3
	je	.du_rep
	cmp	al, 0xF4
	je	.du_hlt
	cmp	al, 0xF5
	je	.du_cmc
	cmp	al, 0xF8
	je	.du_clc
	cmp	al, 0xF9
	je	.du_stc
	cmp	al, 0xFA
	je	.du_cli
	cmp	al, 0xFB
	je	.du_sti
	cmp	al, 0xFC
	je	.du_cld
	cmp	al, 0xFD
	je	.du_std
	cmp	al, 0x8D
	je	.du_lea
	cmp	al, 0xC4
	je	.du_les
	cmp	al, 0xC5
	je	.du_lds
	cmp	al, 0x86
	je	.du_xchg_rm
	cmp	al, 0x87
	je	.du_xchg_rm
	cmp	al, 0x8C
	je	.du_mov_seg_rm
	cmp	al, 0x8E
	je	.du_mov_seg_rm
	cmp	al, 0x84
	je	.du_test_rm
	cmp	al, 0x85
	je	.du_test_rm
	cmp	al, 0xA8
	je	.du_test_al
	cmp	al, 0xA9
	je	.du_test_ax
	cmp	al, 0xC6
	je	.du_mov_rm_imm8
	cmp	al, 0xC7
	je	.du_mov_rm_imm16
	cmp	al, 0x8F
	je	.du_pop_rm
	cmp	al, 0xA0
	je	.du_mov_al_mem
	cmp	al, 0xA1
	je	.du_mov_ax_mem
	cmp	al, 0xA2
	je	.du_mov_mem_al
	cmp	al, 0xA3
	je	.du_mov_mem_ax
	cmp	al, 0xF6
	je	.du_f6f7
	cmp	al, 0xF7
	je	.du_f6f7
	cmp	al, 0xD0
	jb	.du_after_shift
	cmp	al, 0xD3
	jbe	.du_shift_rm
	cmp	al, 0xD7
	je	.du_xlat
.du_after_shift:
	cmp	al, 0x91
	jb	.du_after_xchg_acc
	cmp	al, 0x97
	jbe	.du_xchg_acc
.du_after_xchg_acc:
	cmp	al, 0x74
	je	.du_jz_short
	cmp	al, 0x75
	je	.du_jnz_short
	cmp	al, 0xB0
	jb	.du_after_mov
	cmp	al, 0xB7
	jbe	.du_mov_reg8
	cmp	al, 0xBF
	jbe	.du_mov_reg16

.du_after_mov:
	cmp	al, 0x50
	jb	.du_after_push
	cmp	al, 0x57
	jbe	.du_push
	cmp	al, 0x5F
	jbe	.du_pop

.du_after_push:
	cmp	al, 0x40
	jb	.du_after_inc
	cmp	al, 0x47
	jbe	.du_inc
	cmp	al, 0x4F
	jbe	.du_dec

.du_after_inc:
	cmp	al, 0x40
	jae	.du_after_alu_reg
	mov	dl, al
	and	dl, 7
	cmp	dl, 3
	jbe	.du_alu_rm
	cmp	dl, 4
	je	.du_alu_acc_imm8
	cmp	dl, 5
	je	.du_alu_acc_imm16
.du_after_alu_reg:
	cmp	al, 0x80
	je	.du_alu_imm8
	cmp	al, 0x81
	je	.du_alu_imm16
	cmp	al, 0x83
	je	.du_alu_imm8
	cmp	al, 0x88
	jb	.du_after_mov_rm
	cmp	al, 0x8B
	jbe	.du_mov_rm_reg
.du_after_mov_rm:
	cmp	al, 0xFE
	je	.du_incdec_rm8
	cmp	al, 0xFF
	je	.du_incdec_rm16
	cmp	al, 0x04
	je	.du_add_al
	cmp	al, 0x05
	je	.du_add_ax
	cmp	al, 0x2C
	je	.du_sub_al
	cmp	al, 0x2D
	je	.du_sub_ax
	cmp	al, 0x3C
	je	.du_cmp_al
	cmp	al, 0x3D
	je	.du_cmp_ax
	jmp	.du_db

.du_nop:
	mov	si, str_nop
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_int3:
	mov	si, str_int3
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_ret:
	mov	si, str_ret
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_retf:
	mov	si, str_retf
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_iret:
	mov	si, str_iret
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_int:
	mov	si, str_int
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_jmp_short:
	mov	si, str_jmp
	call	print_str
	mov	al, [es:bx + 1]
	cbw
	mov	dx, bx
	add	dx, 2
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_jmp_near:
	mov	si, str_jmp
	call	print_str
	mov	ax, [es:bx + 1]
	mov	dx, bx
	add	dx, 3
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_call_near:
	mov	si, str_call
	call	print_str
	mov	ax, [es:bx + 1]
	mov	dx, bx
	add	dx, 3
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_jmp_far:
	mov	si, str_jmp_far
	call	print_str
	mov	ax, [es:bx + 3]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 5
	jmp	.du_done
.du_call_far:
	mov	si, str_call_far
	call	print_str
	mov	ax, [es:bx + 3]
	call	print_hex16
	mov	al, ':'
	call	putc
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 5
	jmp	.du_done
.du_jcc_short:
	mov	al, [opcode_byte]
	call	print_jcc_mnemonic
	mov	al, [es:bx + 1]
	cbw
	mov	dx, bx
	add	dx, 2
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_loop_short:
	mov	al, [opcode_byte]
	call	print_loop_mnemonic
	mov	al, [es:bx + 1]
	cbw
	mov	dx, bx
	add	dx, 2
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_push_seg:
	mov	si, str_push
	call	print_str
	mov	al, [opcode_byte]
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 3
	call	print_seg_reg_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_pop_seg:
	mov	si, str_pop
	call	print_str
	mov	al, [opcode_byte]
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 3
	call	print_seg_reg_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_ret_imm:
	mov	si, str_ret_sp
	call	print_str
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_retf_imm:
	mov	si, str_retf_sp
	call	print_str
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_aam:
	mov	si, str_aam
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_aad:
	mov	si, str_aad
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_inout_imm:
	mov	al, [opcode_byte]
	and	al, 2
	jz	.du_in_imm
	mov	si, str_out
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	al, ','
	call	putc
	mov	al, [opcode_byte]
	and	al, 1
	jnz	.du_out_imm_ax
	mov	si, str_al
	call	print_str
	jmp	.du_inout_imm_done
.du_out_imm_ax:
	mov	si, str_ax
	call	print_str
	jmp	.du_inout_imm_done
.du_in_imm:
	mov	si, str_in
	call	print_str
	mov	al, [opcode_byte]
	and	al, 1
	jnz	.du_in_imm_ax
	mov	si, str_al
	call	print_str
	jmp	.du_in_imm_port
.du_in_imm_ax:
	mov	si, str_ax
	call	print_str
.du_in_imm_port:
	mov	al, ','
	call	putc
	mov	al, [es:bx + 1]
	call	print_hex8
.du_inout_imm_done:
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_inout_dx:
	mov	al, [opcode_byte]
	and	al, 2
	jz	.du_in_dx
	mov	si, str_out
	call	print_str
	mov	si, str_dx
	call	print_str
	mov	al, ','
	call	putc
	mov	al, [opcode_byte]
	and	al, 1
	jnz	.du_out_dx_ax
	mov	si, str_al
	call	print_str
	jmp	.du_inout_dx_done
.du_out_dx_ax:
	mov	si, str_ax
	call	print_str
	jmp	.du_inout_dx_done
.du_in_dx:
	mov	si, str_in
	call	print_str
	mov	al, [opcode_byte]
	and	al, 1
	jnz	.du_in_dx_ax
	mov	si, str_al
	call	print_str
	jmp	.du_in_dx_port
.du_in_dx_ax:
	mov	si, str_ax
	call	print_str
.du_in_dx_port:
	mov	al, ','
	call	putc
	mov	si, str_dx
	call	print_str
.du_inout_dx_done:
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_daa:
	mov	si, str_daa
	jmp	.du_one_byte
.du_das:
	mov	si, str_das
	jmp	.du_one_byte
.du_aaa:
	mov	si, str_aaa
	jmp	.du_one_byte
.du_aas:
	mov	si, str_aas
	jmp	.du_one_byte
.du_cbw:
	mov	si, str_cbw
	jmp	.du_one_byte
.du_cwd:
	mov	si, str_cwd
	jmp	.du_one_byte
.du_wait:
	mov	si, str_wait
	jmp	.du_one_byte
.du_pushf:
	mov	si, str_pushf
	jmp	.du_one_byte
.du_popf:
	mov	si, str_popf
	jmp	.du_one_byte
.du_sahf:
	mov	si, str_sahf
	jmp	.du_one_byte
.du_lahf:
	mov	si, str_lahf
	jmp	.du_one_byte
.du_into:
	mov	si, str_into
	jmp	.du_one_byte
.du_lock:
	mov	si, str_lock
	jmp	.du_one_byte
.du_repne:
	mov	si, str_repne
	jmp	.du_one_byte
.du_rep:
	mov	si, str_rep
	jmp	.du_one_byte
.du_hlt:
	mov	si, str_hlt
	jmp	.du_one_byte
.du_cmc:
	mov	si, str_cmc
	jmp	.du_one_byte
.du_clc:
	mov	si, str_clc
	jmp	.du_one_byte
.du_stc:
	mov	si, str_stc
	jmp	.du_one_byte
.du_cli:
	mov	si, str_cli
	jmp	.du_one_byte
.du_sti:
	mov	si, str_sti
	jmp	.du_one_byte
.du_cld:
	mov	si, str_cld
	jmp	.du_one_byte
.du_std:
	mov	si, str_std
	jmp	.du_one_byte
.du_xlat:
	mov	si, str_xlat
	jmp	.du_one_byte
.du_xchg_acc:
	mov	si, str_xchg_ax
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0x90
	call	print_reg16_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_string_op:
	; Emit segment override BEFORE the mnemonic so output is re-assemblable
	; via the leading-prefix syntax in the assembler ("ES: MOVSB").
	mov	al, [disasm_seg_override]
	or	al, al
	jz	.du_so_no_pfx
	cmp	al, 0x26
	je	.du_so_es
	cmp	al, 0x2E
	je	.du_so_cs
	cmp	al, 0x36
	je	.du_so_ss
	mov	si, str_ds
	jmp	.du_so_emit
.du_so_es:
	mov	si, str_es
	jmp	.du_so_emit
.du_so_cs:
	mov	si, str_cs
	jmp	.du_so_emit
.du_so_ss:
	mov	si, str_ss
.du_so_emit:
	call	print_str
	mov	al, ':'
	call	putc
	mov	al, ' '
	call	putc
.du_so_no_pfx:
	mov	al, [opcode_byte]
	call	print_string_mnemonic
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_one_byte:
	call	print_str
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_jz_short:
	mov	si, str_jz
	call	print_str
	mov	al, [es:bx + 1]
	cbw
	mov	dx, bx
	add	dx, 2
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_jnz_short:
	mov	si, str_jnz
	call	print_str
	mov	al, [es:bx + 1]
	cbw
	mov	dx, bx
	add	dx, 2
	add	dx, ax
	mov	ax, dx
	call	print_hex16
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_mov_reg8:
	mov	si, str_mov
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0xB0
	call	print_reg8_name
	mov	al, ','
	call	putc
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_mov_reg16:
	mov	si, str_mov
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0xB8
	call	print_reg16_name
	mov	al, ','
	call	putc
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_push:
	mov	si, str_push
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0x50
	call	print_reg16_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_pop:
	mov	si, str_pop
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0x58
	call	print_reg16_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_inc:
	mov	si, str_inc
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0x40
	call	print_reg16_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_dec:
	mov	si, str_dec
	call	print_str
	mov	al, [opcode_byte]
	sub	al, 0x48
	call	print_reg16_name
	mov	ax, bx
	inc	ax
	jmp	.du_done
.du_add_al:
	mov	si, str_add_al
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_add_ax:
	mov	si, str_add_ax
	call	print_str
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_sub_al:
	mov	si, str_sub_al
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_sub_ax:
	mov	si, str_sub_ax
	call	print_str
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_cmp_al:
	mov	si, str_cmp_al
	call	print_str
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_cmp_ax:
	mov	si, str_cmp_ax
	call	print_str
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_alu_acc_imm8:
	mov	al, [opcode_byte]
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 7
	call	print_alu_mnemonic
	mov	si, str_al
	call	print_str
	mov	al, ','
	call	putc
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_alu_acc_imm16:
	mov	al, [opcode_byte]
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 7
	call	print_alu_mnemonic
	mov	si, str_ax
	call	print_str
	mov	al, ','
	call	putc
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_alu_rm:
	call	du_decode_modrm
	mov	al, [opcode_byte]
	and	al, 1
	jz	.du_alu_rr_width8
	mov	byte [asm_reg_width], 16
	jmp	.du_alu_rr_have_width
.du_alu_rr_width8:
	mov	byte [asm_reg_width], 8
.du_alu_rr_have_width:
	mov	al, [opcode_byte]
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 7
	call	print_alu_mnemonic
	mov	al, [opcode_byte]
	and	al, 2
	jnz	.du_alu_reg_dest
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [asm_src_code]
	call	print_disasm_reg
	jmp	.du_alu_rm_done
.du_alu_reg_dest:
	mov	al, [asm_src_code]
	call	print_disasm_reg
	mov	al, ','
	call	putc
	call	print_disasm_rm_operand
.du_alu_rm_done:
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_alu_imm8:
	call	du_decode_modrm
	mov	al, [asm_src_code]
	call	print_alu_mnemonic
	mov	byte [asm_reg_width], 8
	cmp	byte [opcode_byte], 0x83
	jne	.du_alu_imm8_print
	mov	byte [asm_reg_width], 16
.du_alu_imm8_print:
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	xor	ch, ch
	mov	cl, [asm_instr_len]
	push	bx
	add	bx, cx
	mov	al, [es:bx]
	pop	bx
	call	print_hex8
	mov	ax, bx
	inc	cx
	add	ax, cx
	jmp	.du_done
.du_alu_imm16:
	call	du_decode_modrm
	mov	al, [asm_src_code]
	call	print_alu_mnemonic
	mov	byte [asm_reg_width], 16
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	xor	ch, ch
	mov	cl, [asm_instr_len]
	push	bx
	add	bx, cx
	mov	ax, [es:bx]
	pop	bx
	call	print_hex16
	mov	ax, bx
	add	cx, 2
	add	ax, cx
	jmp	.du_done
.du_mov_rm_reg:
	call	du_decode_modrm
	mov	al, [opcode_byte]
	and	al, 1
	jz	.du_mov_width8
	mov	byte [asm_reg_width], 16
	jmp	.du_mov_have_width
.du_mov_width8:
	mov	byte [asm_reg_width], 8
.du_mov_have_width:
	mov	si, str_mov
	call	print_str
	mov	al, [opcode_byte]
	and	al, 2
	jnz	.du_mov_reg_dest
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [asm_src_code]
	call	print_disasm_reg
	jmp	.du_mov_rm_done
.du_mov_reg_dest:
	mov	al, [asm_src_code]
	call	print_disasm_reg
	mov	al, ','
	call	putc
	call	print_disasm_rm_operand
.du_mov_rm_done:
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_incdec_rm8:
	mov	byte [asm_reg_width], 8
	jmp	.du_incdec_rm
.du_incdec_rm16:
	mov	byte [asm_reg_width], 16
.du_incdec_rm:
	call	du_decode_modrm
	mov	dl, [asm_src_code]
	cmp	byte [opcode_byte], 0xFF
	jne	.du_incdec_only
	cmp	dl, 2
	je	.du_call_rm
	cmp	dl, 3
	je	.du_call_far_rm
	cmp	dl, 4
	je	.du_jmp_rm
	cmp	dl, 5
	je	.du_jmp_far_rm
	cmp	dl, 6
	je	.du_push_rm
.du_incdec_only:
	cmp	dl, 0
	je	.du_incdec_is_inc
	cmp	dl, 1
	jne	.du_db
	mov	si, str_dec
	jmp	.du_incdec_print
.du_incdec_is_inc:
	mov	si, str_inc
.du_incdec_print:
	call	print_str
	call	print_disasm_rm_operand
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_call_rm:
	mov	si, str_call
	jmp	.du_ff_print
.du_call_far_rm:
	mov	si, str_call_far
	jmp	.du_ff_print
.du_jmp_rm:
	mov	si, str_jmp
	jmp	.du_ff_print
.du_jmp_far_rm:
	mov	si, str_jmp_far
	jmp	.du_ff_print
.du_push_rm:
	mov	si, str_push
.du_ff_print:
	call	print_str
	call	print_disasm_rm_operand
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_pop_rm:
	mov	byte [asm_reg_width], 16
	call	du_decode_modrm
	mov	si, str_pop
	call	print_str
	call	print_disasm_rm_operand
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done

.du_mov_al_mem:
	mov	byte [asm_reg_width], 8
	mov	al, 0
	mov	dl, 0				; src=AL, layout: reg, [imm16]
	jmp	.du_mov_acc_mem_print
.du_mov_ax_mem:
	mov	byte [asm_reg_width], 16
	mov	al, 0
	mov	dl, 0				; reg=AX, layout: reg, [imm16]
	jmp	.du_mov_acc_mem_print
.du_mov_mem_al:
	mov	byte [asm_reg_width], 8
	mov	al, 0
	mov	dl, 1				; layout: [imm16], reg
	jmp	.du_mov_acc_mem_print
.du_mov_mem_ax:
	mov	byte [asm_reg_width], 16
	mov	al, 0
	mov	dl, 1
.du_mov_acc_mem_print:
	mov	[asm_reg_code], al		; AL/AX = code 0
	mov	byte [asm_mem_mod], 0
	mov	byte [asm_mem_rm], 6		; direct
	mov	byte [asm_mem_disp_size], 2
	mov	ax, [es:bx + 1]
	mov	[asm_mem_disp], ax
	push	dx
	mov	si, str_mov
	call	print_str
	pop	dx
	cmp	dl, 0
	jne	.du_mov_acc_mem_dst
	; layout: reg, [imm16]
	call	print_disasm_dst_reg
	mov	al, ','
	call	putc
	call	print_disasm_rm_operand
	jmp	.du_mov_acc_mem_done
.du_mov_acc_mem_dst:
	; layout: [imm16], reg
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	call	print_disasm_dst_reg
.du_mov_acc_mem_done:
	mov	ax, bx
	add	ax, 3
	jmp	.du_done

.du_xchg_rm:
	call	du_decode_modrm
	mov	al, [opcode_byte]
	and	al, 1
	jz	.du_xchg_width8
	mov	byte [asm_reg_width], 16
	jmp	.du_xchg_have_width
.du_xchg_width8:
	mov	byte [asm_reg_width], 8
.du_xchg_have_width:
	mov	si, str_xchg
	call	print_str
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [asm_src_code]
	call	print_disasm_reg
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_test_rm:
	call	du_decode_modrm
	mov	al, [opcode_byte]
	and	al, 1
	jz	.du_test_width8
	mov	byte [asm_reg_width], 16
	jmp	.du_test_have_width
.du_test_width8:
	mov	byte [asm_reg_width], 8
.du_test_have_width:
	mov	si, str_test
	call	print_str
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [asm_src_code]
	call	print_disasm_reg
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_test_al:
	mov	si, str_test
	call	print_str
	mov	si, str_al
	call	print_str
	mov	al, ','
	call	putc
	mov	al, [es:bx + 1]
	call	print_hex8
	mov	ax, bx
	add	ax, 2
	jmp	.du_done
.du_test_ax:
	mov	si, str_test
	call	print_str
	mov	si, str_ax
	call	print_str
	mov	al, ','
	call	putc
	mov	ax, [es:bx + 1]
	call	print_hex16
	mov	ax, bx
	add	ax, 3
	jmp	.du_done
.du_mov_seg_rm:
	call	du_decode_modrm
	cmp	byte [asm_src_code], 3
	ja	.du_db
	mov	byte [asm_reg_width], 16
	mov	si, str_mov
	call	print_str
	cmp	byte [opcode_byte], 0x8E
	je	.du_mov_seg_dest
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [asm_src_code]
	call	print_seg_reg_name
	jmp	.du_mov_seg_done
.du_mov_seg_dest:
	mov	al, [asm_src_code]
	call	print_seg_reg_name
	mov	al, ','
	call	putc
	call	print_disasm_rm_operand
.du_mov_seg_done:
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_mov_rm_imm8:
	mov	byte [asm_reg_width], 8
	jmp	.du_mov_rm_imm
.du_mov_rm_imm16:
	mov	byte [asm_reg_width], 16
.du_mov_rm_imm:
	call	du_decode_modrm
	cmp	byte [asm_src_code], 0
	jne	.du_db
	mov	si, str_mov
	call	print_str
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	xor	ch, ch
	mov	cl, [asm_instr_len]
	cmp	byte [asm_reg_width], 8
	jne	.du_mov_rm_imm_word
	push	bx
	add	bx, cx
	mov	al, [es:bx]
	pop	bx
	call	print_hex8
	inc	cx
	jmp	.du_mov_rm_imm_done
.du_mov_rm_imm_word:
	push	bx
	add	bx, cx
	mov	ax, [es:bx]
	pop	bx
	call	print_hex16
	add	cx, 2
.du_mov_rm_imm_done:
	mov	ax, bx
	add	ax, cx
	jmp	.du_done
.du_f6f7:
	call	du_decode_modrm
	cmp	byte [opcode_byte], 0xF6
	jne	.du_f7_width
	mov	byte [asm_reg_width], 8
	jmp	.du_f6f7_group
.du_f7_width:
	mov	byte [asm_reg_width], 16
.du_f6f7_group:
	mov	al, [asm_src_code]
	cmp	al, 0
	je	.du_grp_test
	cmp	al, 2
	je	.du_grp_not
	cmp	al, 3
	je	.du_grp_neg
	cmp	al, 4
	je	.du_grp_mul
	cmp	al, 5
	je	.du_grp_imul
	cmp	al, 6
	je	.du_grp_div
	cmp	al, 7
	je	.du_grp_idiv
	jmp	.du_db
.du_grp_test:
	mov	si, str_test
	call	print_str
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	xor	ch, ch
	mov	cl, [asm_instr_len]
	cmp	byte [asm_reg_width], 8
	jne	.du_grp_test16
	push	bx
	add	bx, cx
	mov	al, [es:bx]
	pop	bx
	call	print_hex8
	inc	cx
	jmp	.du_grp_test_done
.du_grp_test16:
	push	bx
	add	bx, cx
	mov	ax, [es:bx]
	pop	bx
	call	print_hex16
	add	cx, 2
.du_grp_test_done:
	mov	ax, bx
	add	ax, cx
	jmp	.du_done
.du_grp_not:
	mov	si, str_not
	jmp	.du_grp_unary_print
.du_grp_neg:
	mov	si, str_neg
	jmp	.du_grp_unary_print
.du_grp_mul:
	mov	si, str_mul
	jmp	.du_grp_unary_print
.du_grp_imul:
	mov	si, str_imul
	jmp	.du_grp_unary_print
.du_grp_div:
	mov	si, str_div
	jmp	.du_grp_unary_print
.du_grp_idiv:
	mov	si, str_idiv
.du_grp_unary_print:
	call	print_str
	call	print_disasm_rm_operand
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_shift_rm:
	call	du_decode_modrm
	mov	al, [opcode_byte]
	and	al, 1
	jz	.du_shift_width8
	mov	byte [asm_reg_width], 16
	jmp	.du_shift_group
.du_shift_width8:
	mov	byte [asm_reg_width], 8
.du_shift_group:
	mov	al, [asm_src_code]
	call	print_shift_mnemonic
	jc	.du_db
	call	print_disasm_rm_operand
	mov	al, ','
	call	putc
	mov	al, [opcode_byte]
	and	al, 2
	jnz	.du_shift_cl
	mov	al, '1'
	call	putc
	jmp	.du_shift_done
.du_shift_cl:
	mov	si, str_cl
	call	print_str
.du_shift_done:
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_lea:
	mov	si, str_lea
	jmp	.du_load_ptr
.du_lds:
	mov	si, str_lds
	jmp	.du_load_ptr
.du_les:
	mov	si, str_les
.du_load_ptr:
	call	du_decode_modrm
	cmp	byte [asm_mem_mod], 3
	je	.du_db
	mov	byte [asm_reg_width], 16
	call	print_str
	mov	al, [asm_src_code]
	call	print_disasm_reg
	mov	al, ','
	call	putc
	call	print_disasm_rm_operand
	mov	ax, bx
	xor	ch, ch
	mov	cl, [asm_instr_len]
	add	ax, cx
	jmp	.du_done
.du_db:
	mov	si, str_db
	call	print_str
	mov	al, [opcode_byte]
	call	print_hex8
	mov	ax, bx
	inc	ax

.du_done:
	push	ax			; crlf clobbers AL (and thus the returned offset)
	call	crlf
	pop	ax
	pop	es
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	ret

print_alu_mnemonic:
	cmp	al, 0
	je	.pam_add
	cmp	al, 1
	je	.pam_or
	cmp	al, 2
	je	.pam_adc
	cmp	al, 3
	je	.pam_sbb
	cmp	al, 4
	je	.pam_and
	cmp	al, 5
	je	.pam_sub
	cmp	al, 6
	je	.pam_xor
	mov	si, str_cmp
	jmp	print_str
.pam_add:
	mov	si, str_add
	jmp	print_str
.pam_or:
	mov	si, str_or
	jmp	print_str
.pam_adc:
	mov	si, str_adc
	jmp	print_str
.pam_sbb:
	mov	si, str_sbb
	jmp	print_str
.pam_and:
	mov	si, str_and
	jmp	print_str
.pam_sub:
	mov	si, str_sub
	jmp	print_str
.pam_xor:
	mov	si, str_xor
	jmp	print_str

print_disasm_dst_reg:
	mov	al, [asm_reg_code]
	; fall through
print_disasm_reg:
	cmp	byte [asm_reg_width], 8
	je	.pdr8
	call	print_reg16_name
	ret
.pdr8:
	call	print_reg8_name
	ret

du_decode_modrm:
	push	ax
	push	cx
	push	dx
	mov	al, [es:bx + 1]
	mov	[asm_modrm], al
	mov	dl, al
	and	dl, 7
	mov	[asm_mem_rm], dl
	mov	dl, al
	shr	dl, 1
	shr	dl, 1
	shr	dl, 1
	and	dl, 7
	mov	[asm_src_code], dl
	mov	dl, al
	shr	dl, 1
	shr	dl, 1
	shr	dl, 1
	shr	dl, 1
	shr	dl, 1
	shr	dl, 1
	and	dl, 3
	mov	[asm_mem_mod], dl
	mov	byte [asm_mem_disp_size], 0
	mov	word [asm_mem_disp], 0
	mov	byte [asm_instr_len], 2
	cmp	dl, 3
	je	.ddm_done
	cmp	dl, 0
	jne	.ddm_not_mod0
	cmp	byte [asm_mem_rm], 6
	jne	.ddm_done
	mov	ax, [es:bx + 2]
	mov	[asm_mem_disp], ax
	mov	byte [asm_mem_disp_size], 2
	mov	byte [asm_instr_len], 4
	jmp	.ddm_done
.ddm_not_mod0:
	cmp	dl, 1
	jne	.ddm_mod2
	mov	al, [es:bx + 2]
	cbw
	mov	[asm_mem_disp], ax
	mov	byte [asm_mem_disp_size], 1
	mov	byte [asm_instr_len], 3
	jmp	.ddm_done
.ddm_mod2:
	mov	ax, [es:bx + 2]
	mov	[asm_mem_disp], ax
	mov	byte [asm_mem_disp_size], 2
	mov	byte [asm_instr_len], 4
.ddm_done:
	pop	dx
	pop	cx
	pop	ax
	ret

print_shift_mnemonic:
	cmp	al, 0
	je	.psm_rol
	cmp	al, 1
	je	.psm_ror
	cmp	al, 2
	je	.psm_rcl
	cmp	al, 3
	je	.psm_rcr
	cmp	al, 4
	je	.psm_shl
	cmp	al, 5
	je	.psm_shr
	cmp	al, 7
	je	.psm_sar
	stc
	ret
.psm_rol:
	mov	si, str_rol
	jmp	.psm_print
.psm_ror:
	mov	si, str_ror
	jmp	.psm_print
.psm_rcl:
	mov	si, str_rcl
	jmp	.psm_print
.psm_rcr:
	mov	si, str_rcr
	jmp	.psm_print
.psm_shl:
	mov	si, str_shl
	jmp	.psm_print
.psm_shr:
	mov	si, str_shr
	jmp	.psm_print
.psm_sar:
	mov	si, str_sar
.psm_print:
	call	print_str
	clc
	ret

print_jcc_mnemonic:
	and	al, 0x0F
	cmp	al, 0
	je	.pjm_jo
	cmp	al, 1
	je	.pjm_jno
	cmp	al, 2
	je	.pjm_jb
	cmp	al, 3
	je	.pjm_jae
	cmp	al, 4
	je	.pjm_jz
	cmp	al, 5
	je	.pjm_jnz
	cmp	al, 6
	je	.pjm_jbe
	cmp	al, 7
	je	.pjm_ja
	cmp	al, 8
	je	.pjm_js
	cmp	al, 9
	je	.pjm_jns
	cmp	al, 10
	je	.pjm_jp
	cmp	al, 11
	je	.pjm_jnp
	cmp	al, 12
	je	.pjm_jl
	cmp	al, 13
	je	.pjm_jge
	cmp	al, 14
	je	.pjm_jle
	mov	si, str_jg
	jmp	print_str
.pjm_jo:
	mov	si, str_jo
	jmp	print_str
.pjm_jno:
	mov	si, str_jno
	jmp	print_str
.pjm_jb:
	mov	si, str_jb
	jmp	print_str
.pjm_jae:
	mov	si, str_jae
	jmp	print_str
.pjm_jz:
	mov	si, str_jz
	jmp	print_str
.pjm_jnz:
	mov	si, str_jnz
	jmp	print_str
.pjm_jbe:
	mov	si, str_jbe
	jmp	print_str
.pjm_ja:
	mov	si, str_ja
	jmp	print_str
.pjm_js:
	mov	si, str_js
	jmp	print_str
.pjm_jns:
	mov	si, str_jns
	jmp	print_str
.pjm_jp:
	mov	si, str_jp
	jmp	print_str
.pjm_jnp:
	mov	si, str_jnp
	jmp	print_str
.pjm_jl:
	mov	si, str_jl
	jmp	print_str
.pjm_jge:
	mov	si, str_jge
	jmp	print_str
.pjm_jle:
	mov	si, str_jle
	jmp	print_str

print_loop_mnemonic:
	cmp	al, 0xE0
	je	.plm_loopne
	cmp	al, 0xE1
	je	.plm_loope
	cmp	al, 0xE2
	je	.plm_loop
	mov	si, str_jcxz
	jmp	print_str
.plm_loopne:
	mov	si, str_loopne
	jmp	print_str
.plm_loope:
	mov	si, str_loope
	jmp	print_str
.plm_loop:
	mov	si, str_loop
	jmp	print_str

print_string_mnemonic:
	cmp	al, 0xA4
	je	.psm_movsb
	cmp	al, 0xA5
	je	.psm_movsw
	cmp	al, 0xA6
	je	.psm_cmpsb
	cmp	al, 0xA7
	je	.psm_cmpsw
	cmp	al, 0xAA
	je	.psm_stosb
	cmp	al, 0xAB
	je	.psm_stosw
	cmp	al, 0xAC
	je	.psm_lodsb
	cmp	al, 0xAD
	je	.psm_lodsw
	cmp	al, 0xAE
	je	.psm_scasb
	cmp	al, 0xAF
	je	.psm_scasw
	mov	si, str_db
	jmp	print_str
.psm_movsb:
	mov	si, str_movsb
	jmp	print_str
.psm_movsw:
	mov	si, str_movsw
	jmp	print_str
.psm_cmpsb:
	mov	si, str_cmpsb
	jmp	print_str
.psm_cmpsw:
	mov	si, str_cmpsw
	jmp	print_str
.psm_stosb:
	mov	si, str_stosb
	jmp	print_str
.psm_stosw:
	mov	si, str_stosw
	jmp	print_str
.psm_lodsb:
	mov	si, str_lodsb
	jmp	print_str
.psm_lodsw:
	mov	si, str_lodsw
	jmp	print_str
.psm_scasb:
	mov	si, str_scasb
	jmp	print_str
.psm_scasw:
	mov	si, str_scasw
	jmp	print_str

print_disasm_rm_operand:
	cmp	byte [asm_mem_mod], 3
	jne	.pdro_mem
	mov	al, [asm_mem_rm]
	call	print_disasm_reg
	ret
.pdro_mem:
	cmp	byte [asm_reg_width], 8
	jne	.pdro_maybe_word
	mov	si, str_byte
	call	print_str
	jmp	.pdro_open
.pdro_maybe_word:
	cmp	byte [asm_reg_width], 16
	jne	.pdro_open
	mov	si, str_word
	call	print_str
.pdro_open:
	; Print segment-override prefix if present
	mov	al, [disasm_seg_override]
	or	al, al
	jz	.pdro_no_seg_ovr
	cmp	al, 0x26
	je	.pdro_seg_es
	cmp	al, 0x2E
	je	.pdro_seg_cs
	cmp	al, 0x36
	je	.pdro_seg_ss
	mov	si, str_ds
	jmp	.pdro_seg_emit
.pdro_seg_es:
	mov	si, str_es
	jmp	.pdro_seg_emit
.pdro_seg_cs:
	mov	si, str_cs
	jmp	.pdro_seg_emit
.pdro_seg_ss:
	mov	si, str_ss
.pdro_seg_emit:
	call	print_str
	mov	al, ':'
	call	putc
.pdro_no_seg_ovr:
	mov	al, '['
	call	putc
	cmp	byte [asm_mem_mod], 0
	jne	.pdro_not_direct
	cmp	byte [asm_mem_rm], 6
	jne	.pdro_not_direct
	mov	ax, [asm_mem_disp]
	call	print_hex16
	jmp	.pdro_close
.pdro_not_direct:
	mov	al, [asm_mem_rm]
	cmp	al, 0
	je	.pdro_bx_si
	cmp	al, 1
	je	.pdro_bx_di
	cmp	al, 2
	je	.pdro_bp_si
	cmp	al, 3
	je	.pdro_bp_di
	cmp	al, 4
	je	.pdro_si
	cmp	al, 5
	je	.pdro_di
	cmp	al, 6
	je	.pdro_bp
	mov	si, str_bx
	call	print_str
	jmp	.pdro_disp
.pdro_bx_si:
	mov	si, str_bx
	call	print_str
	mov	al, '+'
	call	putc
	mov	si, str_si
	call	print_str
	jmp	.pdro_disp
.pdro_bx_di:
	mov	si, str_bx
	call	print_str
	mov	al, '+'
	call	putc
	mov	si, str_di
	call	print_str
	jmp	.pdro_disp
.pdro_bp_si:
	mov	si, str_bp
	call	print_str
	mov	al, '+'
	call	putc
	mov	si, str_si
	call	print_str
	jmp	.pdro_disp
.pdro_bp_di:
	mov	si, str_bp
	call	print_str
	mov	al, '+'
	call	putc
	mov	si, str_di
	call	print_str
	jmp	.pdro_disp
.pdro_si:
	mov	si, str_si
	call	print_str
	jmp	.pdro_disp
.pdro_di:
	mov	si, str_di
	call	print_str
	jmp	.pdro_disp
.pdro_bp:
	mov	si, str_bp
	call	print_str
.pdro_disp:
	cmp	byte [asm_mem_disp_size], 0
	je	.pdro_close
	mov	ax, [asm_mem_disp]
	or	ax, ax
	jz	.pdro_close
	test	ah, 0x80
	jnz	.pdro_disp_neg
	mov	al, '+'
	call	putc
	mov	ax, [asm_mem_disp]
	jmp	.pdro_disp_abs
.pdro_disp_neg:
	mov	al, '-'
	call	putc
	mov	ax, [asm_mem_disp]
	neg	ax
.pdro_disp_abs:
	cmp	byte [asm_mem_disp_size], 1
	jne	.pdro_disp16
	call	print_hex8
	jmp	.pdro_close
.pdro_disp16:
	call	print_hex16
.pdro_close:
	mov	al, ']'
	call	putc
	ret

assemble_line:
	push	es
	mov	ax, [work_seg]
	mov	es, ax
	mov	di, [work_start]

.al_dispatch:
	; Detect leading segment-override prefix ("ES:" / "CS:" / "SS:" / "DS:"),
	; emit prefix byte, advance past it, then re-dispatch on the next
	; mnemonic. Mirrors the REP/LOCK redispatch path. This allows
	; round-tripping prefixed string ops like "ES: MOVSB".
	cmp	byte [si + 2], ':'
	jne	.al_no_seg_pfx
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'S'
	jne	.al_no_seg_pfx
	cmp	dl, 'E'
	je	.al_seg_pfx_es
	cmp	dl, 'C'
	je	.al_seg_pfx_cs
	cmp	dl, 'S'
	je	.al_seg_pfx_ss
	cmp	dl, 'D'
	je	.al_seg_pfx_ds
	jmp	.al_no_seg_pfx
.al_seg_pfx_es:
	mov	al, 0x26
	jmp	.al_seg_pfx_emit
.al_seg_pfx_cs:
	mov	al, 0x2E
	jmp	.al_seg_pfx_emit
.al_seg_pfx_ss:
	mov	al, 0x36
	jmp	.al_seg_pfx_emit
.al_seg_pfx_ds:
	mov	al, 0x3E
.al_seg_pfx_emit:
	mov	[es:di], al
	inc	di
	add	si, 3
	call	skip_delims
	cmp	byte [si], 0
	je	.al_success
	jmp	.al_dispatch
.al_no_seg_pfx:
	mov	al, [si]
	call	to_upper
	cmp	al, 'D'
	je	.al_db
	cmp	al, 'H'
	je	.al_h_group
	cmp	al, 'N'
	je	.al_nop
	cmp	al, 'I'
	je	.al_i_group
	cmp	al, 'L'
	je	.al_l_group
	cmp	al, 'R'
	je	.al_r_group
	cmp	al, 'J'
	je	.al_jmp
	cmp	al, 'C'
	je	.al_c_group
	cmp	al, 'M'
	je	.al_mov
	cmp	al, 'P'
	je	.al_push_pop
	cmp	al, 'A'
	je	.al_add
	cmp	al, 'S'
	je	.al_s_group
	cmp	al, 'O'
	je	.al_or
	cmp	al, 'X'
	je	.al_xor
	cmp	al, 'T'
	je	.al_t_group
	cmp	al, 'W'
	je	.al_wait
	jmp	.al_fail

.al_db:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'B'
	jne	.al_dec
	add	si, 2
	call	skip_delims
	cmp	byte [si], 0
	je	.al_fail
.al_db_loop:
	call	parse_hex_byte
	jc	.al_fail
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_db_loop
	jmp	.al_success

.al_dec:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	je	.al_daa_das
	cmp	al, 'I'
	je	.al_div
	cmp	al, 'E'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	jne	.al_fail
	add	si, 3
	call	skip_delims
	mov	byte [asm_alu_group], 1
	jmp	.al_inc_dec_common

.al_daa_das:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'A'
	je	.al_daa
	cmp	al, 'S'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0x2F
	jmp	.al_one_byte
.al_daa:
	add	si, 3
	mov	byte [asm_opcode], 0x27
	jmp	.al_one_byte

.al_div:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'V'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 6
	jmp	.emit_unary_reg

.al_nop:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'E'
	je	.al_neg
	cmp	al, 'O'
	je	.al_nop_or_not
	jmp	.al_fail
.al_nop_or_not:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'P'
	je	.al_nop_emit
	cmp	al, 'T'
	je	.al_not
	jmp	.al_fail
.al_nop_emit:
	add	si, 3
	mov	byte [asm_opcode], 0x90
	jmp	.al_one_byte
.al_neg:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'G'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 3
	jmp	.emit_unary_reg
.al_not:
	add	si, 3
	mov	byte [asm_alu_group], 2
	jmp	.emit_unary_reg

.al_i_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'D'
	je	.al_idiv
	cmp	al, 'M'
	je	.al_imul
	cmp	al, 'N'
	je	.al_i_n
	cmp	al, 'R'
	je	.al_iret
	jmp	.al_fail
.al_i_n:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	je	.al_inc
	cmp	al, 'T'
	je	.al_int_or_into
	mov	al, [si + 2]
	cmp	al, 0
	je	.al_in
	cmp	al, ' '
	je	.al_in
	cmp	al, 9
	je	.al_in
	cmp	al, ','
	je	.al_in
	jmp	.al_fail
.al_int_or_into:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'O'
	je	.al_into
.al_int:
	add	si, 3
	call	skip_delims
	cmp	byte [si], '3'
	je	.al_maybe_int3
	call	parse_hex_byte
	jc	.al_fail
	mov	byte [es:di], 0xCD
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_maybe_int3:
	mov	al, [si + 1]
	cmp	al, 0
	je	.al_int3
	cmp	al, ' '
	je	.al_int3
	cmp	al, 9
	je	.al_int3
	cmp	al, ','
	je	.al_int3
	call	parse_hex_byte
	jc	.al_fail
	mov	byte [es:di], 0xCD
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_int3:
	inc	si
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	mov	byte [es:di], 0xCC
	inc	di
	jmp	.al_success
.al_into:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'O'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0xCE
	jmp	.al_one_byte
.al_in:
	add	si, 2
	call	skip_delims
	call	parse_accumulator
	jc	.al_fail
	mov	[asm_accum_kind], al
	call	skip_delims
	call	parse_reg16_code
	jnc	.al_in_dx
	call	parse_hex_byte
	jc	.al_fail
	cmp	byte [asm_accum_kind], 0
	je	.al_in_imm_al
	mov	byte [es:di], 0xE5
	jmp	.al_in_imm_store
.al_in_imm_al:
	mov	byte [es:di], 0xE4
.al_in_imm_store:
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_in_dx:
	cmp	al, 2
	jne	.al_fail
	cmp	byte [asm_accum_kind], 0
	je	.al_in_dx_al
	mov	byte [asm_opcode], 0xED
	jmp	.al_one_byte
.al_in_dx_al:
	mov	byte [asm_opcode], 0xEC
	jmp	.al_one_byte
.al_idiv:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'I'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'V'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_alu_group], 7
	jmp	.emit_unary_reg
.al_imul:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'U'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'L'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_alu_group], 5
	jmp	.emit_unary_reg
.al_iret:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'R'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 4
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	mov	byte [es:di], 0xCF
	inc	di
	jmp	.al_success

.al_inc:
	add	si, 3
	call	skip_delims
	mov	byte [asm_alu_group], 0
	jmp	.al_inc_dec_common

.al_r_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'E'
	je	.al_re_group
	cmp	al, 'O'
	je	.al_ro_group
	cmp	al, 'C'
	je	.al_rc_group
	jmp	.al_fail
.al_re_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'P'
	je	.al_rep_group
	cmp	al, 'T'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'F'
	je	.al_retf
	add	si, 3
	call	skip_delims
	cmp	byte [si], 0
	je	.al_ret_plain
	call	parse_hex_word
	jc	.al_fail
	mov	byte [es:di], 0xC2
	mov	[es:di + 1], ax
	add	di, 3
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_ret_plain:
	mov	byte [asm_opcode], 0xC3
	jmp	.al_one_byte
.al_retf:
	add	si, 4
	call	skip_delims
	cmp	byte [si], 0
	je	.al_retf_plain
	call	parse_hex_word
	jc	.al_fail
	mov	byte [es:di], 0xCA
	mov	[es:di + 1], ax
	add	di, 3
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_retf_plain:
	mov	byte [asm_opcode], 0xCB
	jmp	.al_one_byte
.al_rep_group:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 0
	je	.al_rep
	cmp	al, ' '
	je	.al_rep
	cmp	al, 9
	je	.al_rep
	cmp	al, ','
	je	.al_rep
	cmp	al, 'E'
	je	.al_rep
	cmp	al, 'Z'
	je	.al_rep
	cmp	al, 'N'
	je	.al_repne
	jmp	.al_fail
.al_rep:
	add	si, 3
	cmp	al, 'E'
	je	.al_rep_extra
	cmp	al, 'Z'
	je	.al_rep_extra
	mov	byte [asm_opcode], 0xF3
	jmp	.al_emit_prefix_then_redispatch
.al_rep_extra:
	inc	si
	mov	byte [asm_opcode], 0xF3
	jmp	.al_emit_prefix_then_redispatch
.al_repne:
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'E'
	je	.al_repne_e
	cmp	al, 'Z'
	je	.al_repne_z
	jmp	.al_fail
.al_repne_e:
	add	si, 5
	mov	byte [asm_opcode], 0xF2
	jmp	.al_emit_prefix_then_redispatch
.al_repne_z:
	add	si, 5
	mov	byte [asm_opcode], 0xF2
	jmp	.al_emit_prefix_then_redispatch
.al_emit_prefix_then_redispatch:
	; Emit prefix byte, then either finish (standalone) or re-dispatch
	; on the following mnemonic so REP/REPE/REPNE/LOCK can combine with
	; a following string-op or memory instruction.
	mov	al, [asm_opcode]
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	je	.al_success
	jmp	.al_dispatch
.al_ro_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'L'
	je	.al_rol
	cmp	al, 'R'
	je	.al_ror
	jmp	.al_fail
.al_rol:
	add	si, 3
	mov	byte [asm_alu_group], 0
	jmp	.al_shift_common
.al_ror:
	add	si, 3
	mov	byte [asm_alu_group], 1
	jmp	.al_shift_common
.al_rc_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'L'
	je	.al_rcl
	cmp	al, 'R'
	je	.al_rcr
	jmp	.al_fail
.al_rcl:
	add	si, 3
	mov	byte [asm_alu_group], 2
	jmp	.al_shift_common
.al_rcr:
	add	si, 3
	mov	byte [asm_alu_group], 3
	jmp	.al_shift_common

.al_jmp:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'C'
	je	.al_j_c
	cmp	al, 'O'
	je	.al_jo
	cmp	al, 'N'
	je	.al_j_n
	cmp	al, 'B'
	je	.al_jb
	cmp	al, 'A'
	je	.al_j_a
	cmp	al, 'E'
	je	.al_je
	cmp	al, 'Z'
	je	.al_jz
	cmp	al, 'S'
	je	.al_js
	cmp	al, 'P'
	je	.al_jp
	cmp	al, 'L'
	je	.al_j_l
	cmp	al, 'G'
	je	.al_j_g
	cmp	al, 'M'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'P'
	jne	.al_fail
	add	si, 3
	call	skip_delims
	mov	al, [si]
	call	to_upper
	cmp	al, 'F'
	jne	.al_jmp_near_parse
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	jne	.al_jmp_near_parse
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'R'
	jne	.al_jmp_near_parse
	add	si, 3
	call	skip_delims
	call	parse_mem_operand
	jnc	.al_jmp_far_mem
	call	parse_addr
	jc	.al_fail
	mov	byte [es:di], 0xEA
	mov	[es:di + 1], ax
	mov	[es:di + 3], dx
	add	di, 5
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_jmp_far_mem:
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0xFF
	inc	di
	mov	dl, 5
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_jmp_near_parse:
	call	parse_reg16_code
	jnc	.al_jmp_reg16
	call	parse_mem_operand
	jnc	.al_jmp_mem16
	call	parse_addr
	jc	.al_fail
	cmp	dx, [work_seg]
	jne	.al_fail
	mov	bx, ax
	mov	ax, bx
	sub	ax, di
	sub	ax, 2
	cmp	ax, 0x0080
	jb	.al_jmp_short
	cmp	ax, 0xFF80
	jb	.al_jmp_near
.al_jmp_short:
	mov	byte [es:di], 0xEB
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_jmp_reg16:
	mov	byte [es:di], 0xFF
	or	al, 0xE0			; mod=11, group /4, r/m=reg
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_jmp_mem16:
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0xFF
	inc	di
	mov	dl, 4
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_jmp_near:
	mov	ax, bx
	sub	ax, di
	sub	ax, 3
	mov	byte [es:di], 0xE9
	mov	[es:di + 1], ax
	add	di, 3
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.al_j_c:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'X'
	je	.al_jcxz
	add	si, 2
	mov	byte [asm_opcode], 0x72
	jmp	.al_emit_rel8
.al_jcxz:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'Z'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0xE3
	jmp	.al_emit_rel8
.al_jo:
	add	si, 2
	mov	byte [asm_opcode], 0x70
	jmp	.al_emit_rel8
.al_jb:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	je	.al_jbe
	add	si, 2
	mov	byte [asm_opcode], 0x72
	jmp	.al_emit_rel8
.al_jbe:
	add	si, 3
	mov	byte [asm_opcode], 0x76
	jmp	.al_emit_rel8
.al_je:
	add	si, 2
	mov	byte [asm_opcode], 0x74
	jmp	.al_emit_rel8
.al_jz:
	add	si, 2
	mov	byte [asm_opcode], 0x74
	jmp	.al_emit_rel8
.al_js:
	add	si, 2
	mov	byte [asm_opcode], 0x78
	jmp	.al_emit_rel8
.al_jp:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	je	.al_jpe
	cmp	al, 'O'
	je	.al_jpo_direct
	add	si, 2
	mov	byte [asm_opcode], 0x7A
	jmp	.al_emit_rel8
.al_jpe:
	add	si, 3
	mov	byte [asm_opcode], 0x7A
	jmp	.al_emit_rel8
.al_jpo_direct:
	add	si, 3
	mov	byte [asm_opcode], 0x7B
	jmp	.al_emit_rel8
.al_j_a:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	je	.al_jae
	add	si, 2
	mov	byte [asm_opcode], 0x77
	jmp	.al_emit_rel8
.al_jae:
	add	si, 3
	mov	byte [asm_opcode], 0x73
	jmp	.al_emit_rel8
.al_j_l:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	je	.al_jle
	add	si, 2
	mov	byte [asm_opcode], 0x7C
	jmp	.al_emit_rel8
.al_jle:
	add	si, 3
	mov	byte [asm_opcode], 0x7E
	jmp	.al_emit_rel8
.al_j_g:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'E'
	je	.al_jge
	add	si, 2
	mov	byte [asm_opcode], 0x7F
	jmp	.al_emit_rel8
.al_jge:
	add	si, 3
	mov	byte [asm_opcode], 0x7D
	jmp	.al_emit_rel8
.al_j_n:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'O'
	je	.al_jno
	cmp	al, 'B'
	je	.al_jnb
	cmp	al, 'C'
	je	.al_jnc
	cmp	al, 'E'
	je	.al_jne
	cmp	al, 'Z'
	je	.al_jnz
	cmp	al, 'S'
	je	.al_jns
	cmp	al, 'P'
	je	.al_jnp
	cmp	al, 'L'
	je	.al_jnl
	cmp	al, 'G'
	je	.al_jng
	cmp	al, 'A'
	je	.al_jna
	jmp	.al_fail
.al_jno:
	add	si, 3
	mov	byte [asm_opcode], 0x71
	jmp	.al_emit_rel8
.al_jnb:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'E'
	je	.al_jnbe
	jmp	.al_jnc_common
.al_jnc:
.al_jnc_common:
	add	si, 3
	mov	byte [asm_opcode], 0x73
	jmp	.al_emit_rel8
.al_jnbe:
	add	si, 4
	mov	byte [asm_opcode], 0x77
	jmp	.al_emit_rel8
.al_jne:
.al_jnz:
	add	si, 3
	mov	byte [asm_opcode], 0x75
	jmp	.al_emit_rel8
.al_jns:
	add	si, 3
	mov	byte [asm_opcode], 0x79
	jmp	.al_emit_rel8
.al_jnp:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'O'
	je	.al_jpo
	add	si, 3
	mov	byte [asm_opcode], 0x7B
	jmp	.al_emit_rel8
.al_jpo:
	add	si, 4
	mov	byte [asm_opcode], 0x7B
	jmp	.al_emit_rel8
.al_jnl:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'E'
	je	.al_jnle
	add	si, 3
	mov	byte [asm_opcode], 0x7D
	jmp	.al_emit_rel8
.al_jnle:
	add	si, 4
	mov	byte [asm_opcode], 0x7F
	jmp	.al_emit_rel8
.al_jng:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'E'
	je	.al_jnge
	add	si, 3
	mov	byte [asm_opcode], 0x7E
	jmp	.al_emit_rel8
.al_jnge:
	add	si, 4
	mov	byte [asm_opcode], 0x7C
	jmp	.al_emit_rel8
.al_jna:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'E'
	je	.al_jnae
	add	si, 3
	mov	byte [asm_opcode], 0x76
	jmp	.al_emit_rel8
.al_jnae:
	add	si, 4
	mov	byte [asm_opcode], 0x72
	jmp	.al_emit_rel8

.al_c_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	je	.al_call
	cmp	al, 'B'
	je	.al_cbw
	cmp	al, 'L'
	je	.al_cl_group
	cmp	al, 'M'
	je	.al_cm_group
	cmp	al, 'W'
	je	.al_cwd
	jmp	.al_fail
.al_call:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'L'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'L'
	jne	.al_fail
	add	si, 4
	call	skip_delims
	mov	al, [si]
	call	to_upper
	cmp	al, 'F'
	jne	.al_call_near
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	jne	.al_call_near
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'R'
	jne	.al_call_near
	add	si, 3
	call	skip_delims
	call	parse_mem_operand
	jnc	.al_call_far_mem
	call	parse_addr
	jc	.al_fail
	mov	byte [es:di], 0x9A
	mov	[es:di + 1], ax
	mov	[es:di + 3], dx
	add	di, 5
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_call_far_mem:
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0xFF
	inc	di
	mov	dl, 3
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_call_near:
	call	parse_reg16_code
	jnc	.al_call_reg16
	call	parse_mem_operand
	jnc	.al_call_mem16
	call	parse_addr
	jc	.al_fail
	cmp	dx, [work_seg]
	jne	.al_fail
	sub	ax, di
	sub	ax, 3
	mov	byte [es:di], 0xE8
	mov	[es:di + 1], ax
	add	di, 3
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_call_mem16:
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0xFF
	inc	di
	mov	dl, 2
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_call_reg16:
	mov	byte [es:di], 0xFF
	or	al, 0xD0			; mod=11, group /2, r/m=reg
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_cbw:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'W'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0x98
	jmp	.al_one_byte
.al_cwd:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'D'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0x99
	jmp	.al_one_byte
.al_cl_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	je	.al_clc
	cmp	al, 'D'
	je	.al_cld
	cmp	al, 'I'
	je	.al_cli
	jmp	.al_fail
.al_clc:
	add	si, 3
	mov	byte [asm_opcode], 0xF8
	jmp	.al_one_byte
.al_cld:
	add	si, 3
	mov	byte [asm_opcode], 0xFC
	jmp	.al_one_byte
.al_cli:
	add	si, 3
	mov	byte [asm_opcode], 0xFA
	jmp	.al_one_byte
.al_cm_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'M'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	je	.al_cmc
	cmp	al, 'P'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'S'
	je	.al_cmps
	add	si, 3
	mov	byte [asm_alu_group], 7
	mov	byte [asm_alu_reg_op], 0x38
	mov	byte [asm_alu_acc_op], 0x3C
	jmp	.al_alu_common
.al_cmc:
	add	si, 3
	mov	byte [asm_opcode], 0xF5
	jmp	.al_one_byte
.al_cmps:
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'B'
	je	.al_cmpsb
	cmp	al, 'W'
	jne	.al_fail
	add	si, 5
	mov	byte [asm_opcode], 0xA7
	jmp	.al_one_byte
.al_cmpsb:
	add	si, 5
	mov	byte [asm_opcode], 0xA6
	jmp	.al_one_byte

.al_mov:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'U'
	je	.al_mul
	cmp	al, 'O'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'V'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'S'
	je	.al_movs
	add	si, 3
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_mov_dest_gp
	call	parse_seg_reg_code
	jnc	.al_mov_dest_seg
	call	parse_mem_operand
	jc	.al_fail
	jmp	.al_mov_dest_mem
.al_mov_dest_seg:
	cmp	al, 1
	je	.al_fail
	mov	[asm_seg_code], al
	call	skip_delims
	call	parse_reg16_code
	jnc	.al_mov_seg_reg
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0x8E
	inc	di
	mov	dl, [asm_seg_code]
	call	.emit_mem_modrm
	jmp	.al_mov_done
.al_mov_seg_reg:
	mov	byte [es:di], 0x8E
	mov	dl, [asm_seg_code]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, 0xC0
	or	dl, al
	mov	[es:di + 1], dl
	add	di, 2
	jmp	.al_mov_done
.al_mov_dest_gp:
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	call	skip_delims
	call	parse_gp_reg
	jc	.al_mov_imm
	cmp	ah, [asm_reg_width]
	jne	.al_fail
	mov	[asm_src_code], al
	call	.emit_mov_reg_reg
	jmp	.al_mov_done
.al_mov_imm:
	call	parse_mem_operand
	jnc	.al_mov_gp_mem
	cmp	byte [asm_reg_width], 16
	jne	.al_mov_imm_parse
	call	parse_seg_reg_code
	jc	.al_mov_imm_parse
	mov	byte [es:di], 0x8C
	mov	dl, al
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, 0xC0
	or	dl, [asm_reg_code]
	mov	[es:di + 1], dl
	add	di, 2
	jmp	.al_mov_done
.al_mov_imm_parse:
	call	parse_hex_word
	jc	.al_fail
	cmp	byte [asm_reg_width], 8
	jne	.al_mov16
	cmp	ah, 0
	jne	.al_fail
	mov	dl, [asm_reg_code]
	add	dl, 0xB0
	mov	[es:di], dl
	mov	[es:di + 1], al
	add	di, 2
	jmp	.al_mov_done
.al_mov16:
	mov	dl, [asm_reg_code]
	add	dl, 0xB8
	mov	[es:di], dl
	mov	[es:di + 1], ax
	add	di, 3
	jmp	.al_mov_done
.al_mov_gp_mem:
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_mov_gp_mem_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_mov_gp_mem_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_mov_gp_mem8
	mov	byte [es:di], 0x8B
	jmp	.al_mov_gp_mem_emit
.al_mov_gp_mem8:
	mov	byte [es:di], 0x8A
.al_mov_gp_mem_emit:
	inc	di
	mov	dl, [asm_reg_code]
	call	.emit_mem_modrm
	jmp	.al_mov_done
.al_mov_dest_mem:
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_mov_mem_reg
	call	parse_seg_reg_code
	jnc	.al_mov_mem_seg
	call	parse_hex_word
	jc	.al_fail
	mov	[asm_imm_word], ax
	cmp	byte [asm_mem_width], 8
	je	.al_mov_mem_imm8
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
	mov	byte [es:di], 0xC7
	inc	di
	xor	dl, dl
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], ax
	add	di, 2
	jmp	.al_mov_done
.al_mov_mem_imm8:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0xC6
	inc	di
	xor	dl, dl
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], al
	inc	di
	jmp	.al_mov_done
.al_mov_mem_reg:
	mov	[asm_src_code], al
	mov	[asm_reg_width], ah
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_mov_mem_reg_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_mov_mem_reg_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_mov_mem_reg8
	mov	byte [es:di], 0x89
	jmp	.al_mov_mem_reg_emit
.al_mov_mem_reg8:
	mov	byte [es:di], 0x88
.al_mov_mem_reg_emit:
	inc	di
	mov	dl, [asm_src_code]
	call	.emit_mem_modrm
	jmp	.al_mov_done
.al_mov_mem_seg:
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	[asm_seg_code], al
	mov	byte [es:di], 0x8C
	inc	di
	mov	dl, [asm_seg_code]
	call	.emit_mem_modrm
.al_mov_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_movs:
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'B'
	je	.al_movsb
	cmp	al, 'W'
	jne	.al_fail
	add	si, 5
	mov	byte [asm_opcode], 0xA5
	jmp	.al_one_byte
.al_movsb:
	add	si, 5
	mov	byte [asm_opcode], 0xA4
	jmp	.al_one_byte
.al_mul:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'L'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 4
	jmp	.emit_unary_reg

.al_push_pop:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'U'
	je	.al_push
	cmp	al, 'O'
	je	.al_pop
	jmp	.al_fail
.al_push:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'H'
	jne	.al_fail
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'F'
	je	.al_pushf
	add	si, 4
	call	skip_delims
	call	parse_reg16_code
	jnc	.al_push_reg16
	call	parse_seg_reg_code
	jnc	.al_push_seg
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0xFF
	inc	di
	mov	dl, 6
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_push_seg:
	mov	dl, al
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	add	dl, 0x06
	mov	[es:di], dl
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_push_reg16:
	add	al, 0x50
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_pushf:
	add	si, 5
	mov	byte [asm_opcode], 0x9C
	jmp	.al_one_byte
.al_pop:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'P'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'F'
	je	.al_popf
	add	si, 3
	call	skip_delims
	call	parse_reg16_code
	jnc	.al_pop_reg16
	call	parse_seg_reg_code
	jnc	.al_pop_seg
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.al_fail
	mov	byte [es:di], 0x8F
	inc	di
	xor	dl, dl
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_pop_seg:
	cmp	al, 1
	je	.al_fail
	mov	dl, al
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	add	dl, 0x07
	mov	[es:di], dl
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_pop_reg16:
	add	al, 0x58
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_popf:
	add	si, 4
	mov	byte [asm_opcode], 0x9D
	jmp	.al_one_byte

.al_add:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	je	.al_aaa_aas
	cmp	al, 'D'
	je	.al_add_or_adc
	cmp	al, 'N'
	je	.al_and
	jmp	.al_fail
.al_aaa_aas:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'A'
	je	.al_aaa
	cmp	al, 'D'
	je	.al_aad
	cmp	al, 'M'
	je	.al_aam
	cmp	al, 'S'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0x3F
	jmp	.al_one_byte
.al_aaa:
	add	si, 3
	mov	byte [asm_opcode], 0x37
	jmp	.al_one_byte
.al_aad:
	add	si, 3
	mov	byte [es:di], 0xD5
	mov	al, 0x0A			; default base 10
	call	skip_delims
	cmp	byte [si], 0
	je	.al_aad_emit
	call	parse_hex_byte
	jc	.al_fail
.al_aad_emit:
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_aam:
	add	si, 3
	mov	byte [es:di], 0xD4
	mov	al, 0x0A			; default base 10
	call	skip_delims
	cmp	byte [si], 0
	je	.al_aam_emit
	call	parse_hex_byte
	jc	.al_fail
.al_aam_emit:
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_add_or_adc:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'D'
	je	.al_add_emit
	cmp	al, 'C'
	je	.al_adc_emit
	jmp	.al_fail
.al_add_emit:
	add	si, 3
	mov	byte [asm_alu_group], 0
	mov	byte [asm_alu_reg_op], 0x00
	mov	byte [asm_alu_acc_op], 0x04
	jmp	.al_alu_common
.al_adc_emit:
	add	si, 3
	mov	byte [asm_alu_group], 2
	mov	byte [asm_alu_reg_op], 0x10
	mov	byte [asm_alu_acc_op], 0x14
	jmp	.al_alu_common
.al_and:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'D'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 4
	mov	byte [asm_alu_reg_op], 0x20
	mov	byte [asm_alu_acc_op], 0x24
	jmp	.al_alu_common

.al_s_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	je	.al_sa_group
	cmp	al, 'C'
	je	.al_sc_group
	cmp	al, 'H'
	je	.al_sh_group
	cmp	al, 'T'
	je	.al_st_group
	cmp	al, 'U'
	je	.al_sub
	cmp	al, 'B'
	je	.al_sbb
	jmp	.al_fail
.al_sa_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'H'
	je	.al_sahf
	cmp	al, 'L'
	je	.al_sal
	cmp	al, 'R'
	je	.al_sar
	jmp	.al_fail
.al_sahf:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'F'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0x9E
	jmp	.al_one_byte
.al_sal:
	add	si, 3
	mov	byte [asm_alu_group], 4
	jmp	.al_shift_common
.al_sar:
	add	si, 3
	mov	byte [asm_alu_group], 7
	jmp	.al_shift_common
.al_sc_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'A'
	je	.al_scas
	jmp	.al_fail
.al_scas:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'B'
	je	.al_scasb
	cmp	al, 'W'
	jne	.al_fail
	add	si, 5
	mov	byte [asm_opcode], 0xAF
	jmp	.al_one_byte
.al_scasb:
	add	si, 5
	mov	byte [asm_opcode], 0xAE
	jmp	.al_one_byte
.al_sh_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'L'
	je	.al_shl
	cmp	al, 'R'
	je	.al_shr
	jmp	.al_fail
.al_shl:
	add	si, 3
	mov	byte [asm_alu_group], 4
	jmp	.al_shift_common
.al_shr:
	add	si, 3
	mov	byte [asm_alu_group], 5
	jmp	.al_shift_common
.al_st_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	je	.al_stc
	cmp	al, 'D'
	je	.al_std
	cmp	al, 'I'
	je	.al_sti
	cmp	al, 'O'
	je	.al_stos
	jmp	.al_fail
.al_stc:
	add	si, 3
	mov	byte [asm_opcode], 0xF9
	jmp	.al_one_byte
.al_std:
	add	si, 3
	mov	byte [asm_opcode], 0xFD
	jmp	.al_one_byte
.al_sti:
	add	si, 3
	mov	byte [asm_opcode], 0xFB
	jmp	.al_one_byte
.al_stos:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'B'
	je	.al_stosb
	cmp	al, 'W'
	jne	.al_fail
	add	si, 5
	mov	byte [asm_opcode], 0xAB
	jmp	.al_one_byte
.al_stosb:
	add	si, 5
	mov	byte [asm_opcode], 0xAA
	jmp	.al_one_byte
.al_sub:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'B'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 5
	mov	byte [asm_alu_reg_op], 0x28
	mov	byte [asm_alu_acc_op], 0x2C
	jmp	.al_alu_common
.al_sbb:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'B'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 3
	mov	byte [asm_alu_reg_op], 0x18
	mov	byte [asm_alu_acc_op], 0x1C
	jmp	.al_alu_common

.al_or:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'R'
	je	.al_or_emit
	cmp	al, 'U'
	je	.al_out
	jmp	.al_fail
.al_or_emit:
	add	si, 2
	mov	byte [asm_alu_group], 1
	mov	byte [asm_alu_reg_op], 0x08
	mov	byte [asm_alu_acc_op], 0x0C
	jmp	.al_alu_common
.al_out:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 3
	call	skip_delims
	call	parse_reg16_code
	jnc	.al_out_dx
	call	parse_hex_byte
	jc	.al_fail
	mov	[asm_opcode], al
	call	skip_delims
	call	parse_accumulator
	jc	.al_fail
	cmp	al, 0
	je	.al_out_imm_al
	mov	byte [es:di], 0xE7
	jmp	.al_out_imm_store
.al_out_imm_al:
	mov	byte [es:di], 0xE6
.al_out_imm_store:
	mov	al, [asm_opcode]
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_out_dx:
	cmp	al, 2
	jne	.al_fail
	call	skip_delims
	call	parse_accumulator
	jc	.al_fail
	cmp	al, 0
	je	.al_out_dx_al
	mov	byte [asm_opcode], 0xEF
	jmp	.al_one_byte
.al_out_dx_al:
	mov	byte [asm_opcode], 0xEE
	jmp	.al_one_byte

.al_xor:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'C'
	je	.al_xchg
	cmp	al, 'L'
	je	.al_xlat
	cmp	al, 'O'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'R'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_alu_group], 6
	mov	byte [asm_alu_reg_op], 0x30
	mov	byte [asm_alu_acc_op], 0x34
	jmp	.al_alu_common
.al_xchg:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'H'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'G'
	jne	.al_fail
	add	si, 4
	call	skip_delims
	call	parse_gp_reg
	jc	.al_xchg_mem_dest
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_xchg_reg_reg
	call	parse_mem_operand
	jc	.al_fail
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_xchg_reg_mem_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_xchg_reg_mem_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_xchg_reg_mem8
	mov	byte [es:di], 0x87
	jmp	.al_xchg_reg_mem_emit
.al_xchg_reg_mem8:
	mov	byte [es:di], 0x86
.al_xchg_reg_mem_emit:
	inc	di
	mov	dl, [asm_reg_code]
	call	.emit_mem_modrm
	jmp	.al_xchg_done
.al_xchg_reg_reg:
	cmp	ah, [asm_reg_width]
	jne	.al_fail
	mov	[asm_src_code], al
	cmp	byte [asm_reg_width], 8
	je	.al_xchg8
	mov	byte [es:di], 0x87
	jmp	.al_xchg_modrm
.al_xchg8:
	mov	byte [es:di], 0x86
.al_xchg_modrm:
	mov	dl, [asm_src_code]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	add	di, 2
.al_xchg_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_xchg_mem_dest:
	call	parse_mem_operand
	jc	.al_fail
	call	skip_delims
	call	parse_gp_reg
	jc	.al_fail
	mov	[asm_src_code], al
	mov	[asm_reg_width], ah
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_xchg_mem_reg_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_xchg_mem_reg_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_xchg_mem_reg8
	mov	byte [es:di], 0x87
	jmp	.al_xchg_mem_reg_emit
.al_xchg_mem_reg8:
	mov	byte [es:di], 0x86
.al_xchg_mem_reg_emit:
	inc	di
	mov	dl, [asm_src_code]
	call	.emit_mem_modrm
	jmp	.al_xchg_done
.al_xlat:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'A'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0xD7
	jmp	.al_one_byte

.al_h_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'L'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0xF4
	jmp	.al_one_byte

.al_l_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	je	.al_lahf
	cmp	al, 'D'
	je	.al_lds
	cmp	al, 'E'
	je	.al_le_group
	cmp	al, 'O'
	je	.al_lo_group
	jmp	.al_fail
.al_lahf:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'H'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'F'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0x9F
	jmp	.al_one_byte
.al_le_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'A'
	je	.al_lea
	cmp	al, 'S'
	je	.al_les
	jmp	.al_fail
.al_lea:
	add	si, 3
	mov	byte [asm_opcode], 0x8D
	jmp	.al_load_ptr_common
.al_lds:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	add	si, 3
	mov	byte [asm_opcode], 0xC5
	jmp	.al_load_ptr_common
.al_les:
	add	si, 3
	mov	byte [asm_opcode], 0xC4
.al_load_ptr_common:
	call	skip_delims
	call	parse_reg16_code
	jc	.al_fail
	mov	[asm_reg_code], al
	call	skip_delims
	call	parse_mem_operand
	jc	.al_fail
	mov	al, [asm_opcode]
	mov	[es:di], al
	inc	di
	mov	dl, [asm_reg_code]
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_lo_group:
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'C'
	je	.al_lock
	cmp	al, 'D'
	je	.al_lods
	cmp	al, 'O'
	je	.al_loop_group
	jmp	.al_fail
.al_lock:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'K'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0xF0
	jmp	.al_emit_prefix_then_redispatch
.al_lods:
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'B'
	je	.al_lodsb
	cmp	al, 'W'
	jne	.al_fail
	add	si, 5
	mov	byte [asm_opcode], 0xAD
	jmp	.al_one_byte
.al_lodsb:
	add	si, 5
	mov	byte [asm_opcode], 0xAC
	jmp	.al_one_byte
.al_loop_group:
	mov	al, [si + 4]
	call	to_upper
	cmp	al, 'N'
	je	.al_loopne
	cmp	al, 'E'
	je	.al_loope
	cmp	al, 'Z'
	je	.al_loopz
	add	si, 4
	mov	byte [asm_opcode], 0xE2
	jmp	.al_emit_rel8
.al_loopne:
	mov	al, [si + 5]
	call	to_upper
	cmp	al, 'E'
	je	.al_loopne6
	cmp	al, 'Z'
	je	.al_loopne6
	jmp	.al_fail
.al_loopne6:
	add	si, 6
	mov	byte [asm_opcode], 0xE0
	jmp	.al_emit_rel8
.al_loope:
	add	si, 5
	mov	byte [asm_opcode], 0xE1
	jmp	.al_emit_rel8
.al_loopz:
	add	si, 5
	mov	byte [asm_opcode], 0xE1
	jmp	.al_emit_rel8

.al_t_group:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'E'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'S'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 4
	call	skip_delims
	call	parse_gp_reg
	jc	.al_test_mem_dest
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	call	skip_delims
	call	parse_gp_reg
	jc	.al_test_try_mem
	cmp	ah, [asm_reg_width]
	jne	.al_fail
	mov	[asm_src_code], al
	call	.emit_test_reg_reg
	jmp	.al_test_done
.al_test_try_mem:
	call	parse_mem_operand
	jnc	.al_test_reg_mem
.al_test_imm:
	call	parse_hex_word
	jc	.al_fail
	call	.emit_test_reg_imm
	jmp	.al_test_done
.al_test_reg_mem:
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_test_reg_mem_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_test_reg_mem_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_test_reg_mem8
	mov	byte [es:di], 0x85
	jmp	.al_test_reg_mem_emit
.al_test_reg_mem8:
	mov	byte [es:di], 0x84
.al_test_reg_mem_emit:
	inc	di
	mov	dl, [asm_reg_code]
	call	.emit_mem_modrm
	jmp	.al_test_done
.al_test_mem_dest:
	call	parse_mem_operand
	jc	.al_fail
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_test_mem_reg
	call	parse_hex_word
	jc	.al_fail
	mov	[asm_imm_word], ax
	cmp	byte [asm_mem_width], 8
	je	.al_test_mem_imm8
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
	mov	byte [es:di], 0xF7
	inc	di
	xor	dl, dl
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], ax
	add	di, 2
	jmp	.al_test_done
.al_test_mem_imm8:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0xF6
	inc	di
	xor	dl, dl
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], al
	inc	di
	jmp	.al_test_done
.al_test_mem_reg:
	mov	[asm_src_code], al
	mov	[asm_reg_width], ah
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_test_mem_reg_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_test_mem_reg_width_ok:
	cmp	byte [asm_reg_width], 8
	je	.al_test_mem_reg8
	mov	byte [es:di], 0x85
	jmp	.al_test_mem_reg_emit
.al_test_mem_reg8:
	mov	byte [es:di], 0x84
.al_test_mem_reg_emit:
	inc	di
	mov	dl, [asm_src_code]
	call	.emit_mem_modrm
.al_test_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.al_wait:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'A'
	jne	.al_fail
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'I'
	jne	.al_fail
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'T'
	jne	.al_fail
	add	si, 4
	mov	byte [asm_opcode], 0x9B
	jmp	.al_one_byte

.al_alu_common:
	call	skip_delims
	call	parse_gp_reg
	jc	.al_alu_dest_mem
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_alu_reg_reg
	call	parse_mem_operand
	jnc	.al_alu_reg_mem
	call	parse_hex_word
	jc	.al_fail
	call	.emit_alu_reg_imm
	jmp	.al_alu_done
.al_alu_reg_reg:
	cmp	ah, [asm_reg_width]
	jne	.al_fail
	mov	[asm_src_code], al
	call	.emit_alu_reg_reg
	jmp	.al_alu_done
.al_alu_reg_mem:
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_alu_reg_mem_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_alu_reg_mem_width_ok:
	mov	dl, [asm_alu_reg_op]
	add	dl, 2
	cmp	byte [asm_reg_width], 8
	je	.al_alu_reg_mem_opcode
	inc	dl
.al_alu_reg_mem_opcode:
	mov	[es:di], dl
	inc	di
	mov	dl, [asm_reg_code]
	call	.emit_mem_modrm
	jmp	.al_alu_done

.al_alu_dest_mem:
	call	parse_mem_operand
	jc	.al_fail
	call	skip_delims
	call	parse_gp_reg
	jnc	.al_alu_mem_reg
	call	parse_hex_word
	jc	.al_fail
	mov	[asm_imm_word], ax
	cmp	byte [asm_mem_width], 8
	je	.al_alu_mem_imm8
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
	mov	byte [es:di], 0x81
	inc	di
	mov	dl, [asm_alu_group]
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], ax
	add	di, 2
	jmp	.al_alu_done
.al_alu_mem_imm8:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0x80
	inc	di
	mov	dl, [asm_alu_group]
	call	.emit_mem_modrm
	mov	ax, [asm_imm_word]
	mov	[es:di], al
	inc	di
	jmp	.al_alu_done
.al_alu_mem_reg:
	mov	[asm_src_code], al
	mov	[asm_reg_width], ah
	mov	al, [asm_mem_width]
	or	al, al
	jz	.al_alu_mem_reg_width_ok
	cmp	al, [asm_reg_width]
	jne	.al_fail
.al_alu_mem_reg_width_ok:
	mov	dl, [asm_alu_reg_op]
	cmp	byte [asm_reg_width], 8
	je	.al_alu_mem_reg_opcode
	inc	dl
.al_alu_mem_reg_opcode:
	mov	[es:di], dl
	inc	di
	mov	dl, [asm_src_code]
	call	.emit_mem_modrm
.al_alu_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.al_inc_dec_common:
	call	parse_gp_reg
	jc	.al_inc_dec_mem
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	cmp	ah, 8
	je	.al_inc_dec8
	mov	dl, [asm_reg_code]
	cmp	byte [asm_alu_group], 0
	je	.al_inc16
	add	dl, 0x48
	jmp	.al_incdec16_emit
.al_inc16:
	add	dl, 0x40
.al_incdec16_emit:
	mov	[es:di], dl
	inc	di
	jmp	.al_inc_dec_done
.al_inc_dec8:
	mov	byte [es:di], 0xFE
	mov	dl, [asm_reg_code]
	or	dl, 0xC0
	cmp	byte [asm_alu_group], 0
	je	.al_incdec8_emit
	or	dl, 0x08
.al_incdec8_emit:
	mov	[es:di + 1], dl
	add	di, 2
.al_inc_dec_done:
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.al_inc_dec_mem:
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.al_inc_dec_mem8
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
	mov	byte [es:di], 0xFF
	jmp	.al_inc_dec_mem_group
.al_inc_dec_mem8:
	mov	byte [es:di], 0xFE
.al_inc_dec_mem_group:
	inc	di
	mov	dl, [asm_alu_group]
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.emit_mov_reg_reg:
	mov	dl, 0x88
	cmp	byte [asm_reg_width], 8
	je	.emrr_opcode
	inc	dl
.emrr_opcode:
	mov	[es:di], dl
	mov	dl, [asm_src_code]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	add	di, 2
	ret

.emit_alu_reg_reg:
	mov	dl, [asm_alu_reg_op]
	cmp	byte [asm_reg_width], 8
	je	.earr_opcode
	inc	dl
.earr_opcode:
	mov	[es:di], dl
	mov	dl, [asm_src_code]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	add	di, 2
	ret

.emit_alu_reg_imm:
	cmp	byte [asm_reg_code], 0
	jne	.eari_general
	cmp	byte [asm_reg_width], 8
	je	.eari_acc8
	mov	dl, [asm_alu_acc_op]
	inc	dl
	mov	[es:di], dl
	mov	[es:di + 1], ax
	add	di, 3
	ret
.eari_acc8:
	cmp	ah, 0
	jne	.al_fail
	mov	dl, [asm_alu_acc_op]
	mov	[es:di], dl
	mov	[es:di + 1], al
	add	di, 2
	ret
.eari_general:
	cmp	byte [asm_reg_width], 8
	je	.eari_general8
	mov	byte [es:di], 0x81
	mov	dl, [asm_alu_group]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	mov	[es:di + 2], ax
	add	di, 4
	ret
.eari_general8:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0x80
	mov	dl, [asm_alu_group]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	mov	[es:di + 2], al
	add	di, 3
	ret

.al_one_byte:
	mov	al, [asm_opcode]
	mov	[es:di], al
	inc	di
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.al_emit_rel8:
	call	skip_delims
	call	parse_addr
	jc	.al_fail
	cmp	dx, [work_seg]
	jne	.al_fail
	sub	ax, di
	sub	ax, 2
	cmp	ax, 0x0080
	jb	.aer_ok
	cmp	ax, 0xFF80
	jb	.al_fail
.aer_ok:
	mov	dl, [asm_opcode]
	mov	[es:di], dl
	mov	[es:di + 1], al
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.emit_unary_reg:
	call	skip_delims
	call	parse_gp_reg
	jc	.eur_mem
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	cmp	ah, 8
	je	.eur8
	mov	byte [es:di], 0xF7
	jmp	.eur_modrm
.eur8:
	mov	byte [es:di], 0xF6
.eur_modrm:
	mov	dl, [asm_alu_group]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, 0xC0
	or	dl, [asm_reg_code]
	mov	[es:di + 1], dl
	add	di, 2
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success
.eur_mem:
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.eur_mem8
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
	mov	byte [es:di], 0xF7
	jmp	.eur_mem_modrm
.eur_mem8:
	mov	byte [es:di], 0xF6
.eur_mem_modrm:
	inc	di
	mov	dl, [asm_alu_group]
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.al_shift_common:
	call	skip_delims
	call	parse_gp_reg
	jc	.asc_mem
	mov	[asm_reg_code], al
	mov	[asm_reg_width], ah
	mov	byte [asm_mem_width], ah
	mov	byte [asm_mem_mod], 3
	mov	byte [asm_mem_disp_size], 0
	mov	al, [asm_reg_code]
	mov	[asm_mem_rm], al
	jmp	.asc_have_operand
.asc_mem:
	call	parse_mem_operand
	jc	.al_fail
	cmp	byte [asm_mem_width], 8
	je	.asc_have_operand
	cmp	byte [asm_mem_width], 16
	jne	.al_fail
.asc_have_operand:
	call	skip_delims
	mov	al, [si]
	call	to_upper
	cmp	al, 'C'
	jne	.asc_imm
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'L'
	jne	.asc_imm
	add	si, 2
	cmp	byte [asm_reg_width], 8
	je	.asc_cl8
	mov	byte [es:di], 0xD3
	jmp	.asc_emit
.asc_cl8:
	mov	byte [es:di], 0xD2
	jmp	.asc_emit
.asc_imm:
	call	parse_hex_byte
	jc	.al_fail
	cmp	al, 1
	jne	.al_fail
	cmp	byte [asm_reg_width], 8
	je	.asc_one8
	mov	byte [es:di], 0xD1
	jmp	.asc_emit
.asc_one8:
	mov	byte [es:di], 0xD0
.asc_emit:
	mov	dl, [asm_alu_group]
	inc	di
	call	.emit_mem_modrm
	call	skip_delims
	cmp	byte [si], 0
	jne	.al_fail
	jmp	.al_success

.emit_test_reg_reg:
	cmp	byte [asm_reg_width], 8
	je	.etrr8
	mov	byte [es:di], 0x85
	jmp	.etrr_modrm
.etrr8:
	mov	byte [es:di], 0x84
.etrr_modrm:
	mov	dl, [asm_src_code]
	shl	dl, 1
	shl	dl, 1
	shl	dl, 1
	or	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	add	di, 2
	ret

.emit_test_reg_imm:
	cmp	byte [asm_reg_code], 0
	jne	.etri_general
	cmp	byte [asm_reg_width], 8
	je	.etri_al
	mov	byte [es:di], 0xA9
	mov	[es:di + 1], ax
	add	di, 3
	ret
.etri_al:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0xA8
	mov	[es:di + 1], al
	add	di, 2
	ret
.etri_general:
	cmp	byte [asm_reg_width], 8
	je	.etri_general8
	mov	byte [es:di], 0xF7
	mov	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	mov	[es:di + 2], ax
	add	di, 4
	ret
.etri_general8:
	cmp	ah, 0
	jne	.al_fail
	mov	byte [es:di], 0xF6
	mov	dl, [asm_reg_code]
	or	dl, 0xC0
	mov	[es:di + 1], dl
	mov	[es:di + 2], al
	add	di, 3
	ret

.emit_mem_modrm:
	cmp	byte [asm_seg_override], 0
	je	.emm_no_prefix
	; Insert segment-override prefix before the just-emitted opcode at di-1.
	; All 8086 opcodes that take a memory operand are single-byte, so we
	; shift one byte forward to make room for the prefix.
	push	ax
	dec	di
	mov	al, [es:di]
	push	ax			; save opcode
	mov	al, [asm_seg_override]
	mov	[es:di], al		; write prefix at original opcode position
	inc	di
	pop	ax
	mov	[es:di], al		; rewrite opcode after prefix
	inc	di
	mov	byte [asm_seg_override], 0
	pop	ax
.emm_no_prefix:
	mov	al, [asm_mem_mod]
	shl	al, 1
	shl	al, 1
	shl	al, 1
	shl	al, 1
	shl	al, 1
	shl	al, 1
	mov	ah, dl
	shl	ah, 1
	shl	ah, 1
	shl	ah, 1
	or	al, ah
	or	al, [asm_mem_rm]
	mov	[es:di], al
	inc	di
	cmp	byte [asm_mem_disp_size], 0
	je	.emm_done
	mov	ax, [asm_mem_disp]
	cmp	byte [asm_mem_disp_size], 1
	jne	.emm_disp16
	mov	[es:di], al
	inc	di
	ret
.emm_disp16:
	mov	[es:di], ax
	add	di, 2
.emm_done:
	ret

.al_success:
	mov	[work_start], di
	pop	es
	clc
	ret
.al_fail:
	pop	es
	stc
	ret

parse_accumulator:
	mov	al, [si]
	call	to_upper
	cmp	al, 'A'
	jne	.pa_fail
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'L'
	je	.pa_al
	cmp	al, 'X'
	jne	.pa_fail
	add	si, 2
	mov	al, 1
	clc
	ret
.pa_al:
	add	si, 2
	xor	al, al
	clc
	ret
.pa_fail:
	stc
	ret

parse_gp_reg:
	call	parse_reg8_code
	jnc	.pgr_done8
	call	parse_reg16_code
	jc	.pgr_fail
	mov	ah, 16
	clc
	ret
.pgr_done8:
	mov	ah, 8
	clc
	ret
.pgr_fail:
	stc
	ret

parse_mem_operand:
	push	bx
	push	cx
	push	dx
	push	di
	push	si
	mov	byte [asm_mem_width], 0
	mov	byte [asm_ea_mask], 0
	mov	byte [asm_ea_seen], 0
	mov	word [asm_mem_disp], 0
	mov	byte [asm_seg_override], 0

	call	skip_spaces
	mov	al, [si]
	call	to_upper
	cmp	al, 'B'
	je	.pmo_maybe_byte
	cmp	al, 'W'
	je	.pmo_maybe_word
	jmp	.pmo_after_size
.pmo_maybe_byte:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'Y'
	jne	.pmo_after_size
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'T'
	jne	.pmo_after_size
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'E'
	jne	.pmo_after_size
	add	si, 4
	mov	byte [asm_mem_width], 8
	jmp	.pmo_after_size_word
.pmo_maybe_word:
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'O'
	jne	.pmo_after_size
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'R'
	jne	.pmo_after_size
	mov	al, [si + 3]
	call	to_upper
	cmp	al, 'D'
	jne	.pmo_after_size
	add	si, 4
	mov	byte [asm_mem_width], 16
.pmo_after_size_word:
	call	skip_spaces
	mov	al, [si]
	call	to_upper
	cmp	al, 'P'
	jne	.pmo_after_size
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'T'
	jne	.pmo_after_size
	mov	al, [si + 2]
	call	to_upper
	cmp	al, 'R'
	jne	.pmo_after_size
	add	si, 3

.pmo_after_size:
	call	skip_spaces
	; Check for optional segment-override prefix: ES:/CS:/SS:/DS:
	mov	al, [si + 2]
	cmp	al, ':'
	jne	.pmo_no_seg_ovr
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	cmp	al, 'S'
	jne	.pmo_no_seg_ovr
	cmp	dl, 'E'
	je	.pmo_seg_es
	cmp	dl, 'C'
	je	.pmo_seg_cs
	cmp	dl, 'S'
	je	.pmo_seg_ss
	cmp	dl, 'D'
	je	.pmo_seg_ds
	jmp	.pmo_no_seg_ovr
.pmo_seg_es:
	mov	byte [asm_seg_override], 0x26
	jmp	.pmo_seg_consume
.pmo_seg_cs:
	mov	byte [asm_seg_override], 0x2E
	jmp	.pmo_seg_consume
.pmo_seg_ss:
	mov	byte [asm_seg_override], 0x36
	jmp	.pmo_seg_consume
.pmo_seg_ds:
	mov	byte [asm_seg_override], 0x3E
.pmo_seg_consume:
	add	si, 3
	call	skip_spaces
.pmo_no_seg_ovr:
	cmp	byte [si], '['
	jne	.pmo_fail
	inc	si

.pmo_loop:
	call	skip_spaces
	mov	byte [asm_ea_sign], 0
	cmp	byte [si], '+'
	je	.pmo_plus
	cmp	byte [si], '-'
	je	.pmo_minus
	jmp	.pmo_term
.pmo_plus:
	inc	si
	jmp	.pmo_term
.pmo_minus:
	inc	si
	mov	byte [asm_ea_sign], 1
.pmo_term:
	call	skip_spaces
	call	parse_reg16_code
	jnc	.pmo_reg
	call	parse_hex_word
	jc	.pmo_fail
	cmp	byte [asm_ea_sign], 0
	je	.pmo_disp_add
	neg	ax
.pmo_disp_add:
	add	[asm_mem_disp], ax
	mov	byte [asm_ea_seen], 1
	jmp	.pmo_after_term

.pmo_reg:
	cmp	byte [asm_ea_sign], 0
	jne	.pmo_fail
	cmp	al, 3			; BX
	je	.pmo_reg_bx
	cmp	al, 5			; BP
	je	.pmo_reg_bp
	cmp	al, 6			; SI
	je	.pmo_reg_si
	cmp	al, 7			; DI
	je	.pmo_reg_di
	jmp	.pmo_fail
.pmo_reg_bx:
	mov	dl, 1
	jmp	.pmo_or_mask
.pmo_reg_bp:
	mov	dl, 2
	jmp	.pmo_or_mask
.pmo_reg_si:
	mov	dl, 4
	jmp	.pmo_or_mask
.pmo_reg_di:
	mov	dl, 8
.pmo_or_mask:
	mov	al, [asm_ea_mask]
	test	al, dl
	jnz	.pmo_fail
	or	al, dl
	mov	[asm_ea_mask], al
	mov	byte [asm_ea_seen], 1

.pmo_after_term:
	call	skip_spaces
	cmp	byte [si], ']'
	je	.pmo_done_terms
	cmp	byte [si], '+'
	je	.pmo_loop
	cmp	byte [si], '-'
	je	.pmo_loop
	jmp	.pmo_fail

.pmo_done_terms:
	inc	si
	cmp	byte [asm_ea_seen], 0
	je	.pmo_fail
	mov	al, [asm_ea_mask]
	or	al, al
	jz	.pmo_direct
	cmp	al, 5			; BX+SI
	je	.pmo_rm0
	cmp	al, 9			; BX+DI
	je	.pmo_rm1
	cmp	al, 6			; BP+SI
	je	.pmo_rm2
	cmp	al, 10			; BP+DI
	je	.pmo_rm3
	cmp	al, 4			; SI
	je	.pmo_rm4
	cmp	al, 8			; DI
	je	.pmo_rm5
	cmp	al, 2			; BP
	je	.pmo_rm6_bp
	cmp	al, 1			; BX
	je	.pmo_rm7
	jmp	.pmo_fail
.pmo_rm0:
	mov	byte [asm_mem_rm], 0
	jmp	.pmo_choose_mod
.pmo_rm1:
	mov	byte [asm_mem_rm], 1
	jmp	.pmo_choose_mod
.pmo_rm2:
	mov	byte [asm_mem_rm], 2
	jmp	.pmo_choose_mod
.pmo_rm3:
	mov	byte [asm_mem_rm], 3
	jmp	.pmo_choose_mod
.pmo_rm4:
	mov	byte [asm_mem_rm], 4
	jmp	.pmo_choose_mod
.pmo_rm5:
	mov	byte [asm_mem_rm], 5
	jmp	.pmo_choose_mod
.pmo_rm6_bp:
	mov	byte [asm_mem_rm], 6
	jmp	.pmo_choose_mod
.pmo_rm7:
	mov	byte [asm_mem_rm], 7

.pmo_choose_mod:
	mov	ax, [asm_mem_disp]
	or	ax, ax
	jne	.pmo_has_disp
	cmp	byte [asm_mem_rm], 6
	je	.pmo_bp_zero_disp
	mov	byte [asm_mem_mod], 0
	mov	byte [asm_mem_disp_size], 0
	jmp	.pmo_success
.pmo_bp_zero_disp:
	mov	byte [asm_mem_mod], 1
	mov	byte [asm_mem_disp_size], 1
	jmp	.pmo_success
.pmo_has_disp:
	cmp	ax, 0x0080
	jb	.pmo_disp8
	cmp	ax, 0xFF80
	jae	.pmo_disp8
	mov	byte [asm_mem_mod], 2
	mov	byte [asm_mem_disp_size], 2
	jmp	.pmo_success
.pmo_disp8:
	mov	byte [asm_mem_mod], 1
	mov	byte [asm_mem_disp_size], 1
	jmp	.pmo_success

.pmo_direct:
	mov	byte [asm_mem_rm], 6
	mov	byte [asm_mem_mod], 0
	mov	byte [asm_mem_disp_size], 2
	jmp	.pmo_success

.pmo_success:
	pop	ax
	pop	di
	pop	dx
	pop	cx
	pop	bx
	clc
	ret
.pmo_fail:
	pop	si
	pop	di
	pop	dx
	pop	cx
	pop	bx
	stc
	ret

parse_reg16_code:
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	mov	dh, al
	cmp	dl, 'A'
	jne	.pr16_b
	cmp	dh, 'X'
	jne	.pr16_fail
	add	si, 2
	xor	al, al
	clc
	ret
.pr16_b:
	cmp	dl, 'B'
	jne	.pr16_c
	cmp	dh, 'X'
	je	.pr16_bx
	cmp	dh, 'P'
	je	.pr16_bp
	jmp	.pr16_fail
.pr16_bx:
	add	si, 2
	mov	al, 3
	clc
	ret
.pr16_bp:
	add	si, 2
	mov	al, 5
	clc
	ret
.pr16_c:
	cmp	dl, 'C'
	jne	.pr16_d
	cmp	dh, 'X'
	jne	.pr16_fail
	add	si, 2
	mov	al, 1
	clc
	ret
.pr16_d:
	cmp	dl, 'D'
	jne	.pr16_s
	cmp	dh, 'X'
	jne	.pr16_di
	add	si, 2
	mov	al, 2
	clc
	ret
.pr16_di:
	cmp	dh, 'I'
	jne	.pr16_fail
	add	si, 2
	mov	al, 7
	clc
	ret
.pr16_s:
	cmp	dl, 'S'
	jne	.pr16_fail
	cmp	dh, 'I'
	je	.pr16_si
	cmp	dh, 'P'
	je	.pr16_sp
	jmp	.pr16_fail
.pr16_si:
	add	si, 2
	mov	al, 6
	clc
	ret
.pr16_sp:
	add	si, 2
	mov	al, 4
	clc
	ret
.pr16_fail:
	stc
	ret

parse_reg8_code:
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	mov	dh, al
	cmp	dl, 'A'
	jne	.pr8_b
	cmp	dh, 'L'
	je	.pr8_al
	cmp	dh, 'H'
	je	.pr8_ah
	jmp	.pr8_fail
.pr8_al:
	add	si, 2
	xor	al, al
	clc
	ret
.pr8_ah:
	add	si, 2
	mov	al, 4
	clc
	ret
.pr8_b:
	cmp	dl, 'B'
	jne	.pr8_c
	cmp	dh, 'L'
	je	.pr8_bl
	cmp	dh, 'H'
	je	.pr8_bh
	jmp	.pr8_fail
.pr8_bl:
	add	si, 2
	mov	al, 3
	clc
	ret
.pr8_bh:
	add	si, 2
	mov	al, 7
	clc
	ret
.pr8_c:
	cmp	dl, 'C'
	jne	.pr8_d
	cmp	dh, 'L'
	je	.pr8_cl
	cmp	dh, 'H'
	je	.pr8_ch
	jmp	.pr8_fail
.pr8_cl:
	add	si, 2
	mov	al, 1
	clc
	ret
.pr8_ch:
	add	si, 2
	mov	al, 5
	clc
	ret
.pr8_d:
	cmp	dl, 'D'
	jne	.pr8_fail
	cmp	dh, 'L'
	je	.pr8_dl
	cmp	dh, 'H'
	je	.pr8_dh
	jmp	.pr8_fail
.pr8_dl:
	add	si, 2
	mov	al, 2
	clc
	ret
.pr8_dh:
	add	si, 2
	mov	al, 6
	clc
	ret
.pr8_fail:
	stc
	ret

parse_seg_reg_code:
	; Reject if 3rd char is ':' — that's a segment-override prefix, not a
	; segment register operand (e.g., "ES:[BX]" must fall through to
	; parse_mem_operand).
	cmp	byte [si + 2], ':'
	je	.psr_fail
	mov	al, [si]
	call	to_upper
	mov	dl, al
	mov	al, [si + 1]
	call	to_upper
	mov	dh, al
	cmp	dl, 'E'
	jne	.psr_c
	cmp	dh, 'S'
	jne	.psr_fail
	add	si, 2
	xor	al, al
	clc
	ret
.psr_c:
	cmp	dl, 'C'
	jne	.psr_s
	cmp	dh, 'S'
	jne	.psr_fail
	add	si, 2
	mov	al, 1
	clc
	ret
.psr_s:
	cmp	dl, 'S'
	jne	.psr_d
	cmp	dh, 'S'
	jne	.psr_fail
	add	si, 2
	mov	al, 2
	clc
	ret
.psr_d:
	cmp	dl, 'D'
	jne	.psr_fail
	cmp	dh, 'S'
	jne	.psr_fail
	add	si, 2
	mov	al, 3
	clc
	ret
.psr_fail:
	stc
	ret

print_reg16_name:
	and	al, 7
	cmp	al, 0
	je	.prn_ax
	cmp	al, 1
	je	.prn_cx
	cmp	al, 2
	je	.prn_dx
	cmp	al, 3
	je	.prn_bx
	cmp	al, 4
	je	.prn_sp
	cmp	al, 5
	je	.prn_bp
	cmp	al, 6
	je	.prn_si
	mov	si, str_di
	jmp	print_str
.prn_ax:
	mov	si, str_ax
	jmp	print_str
.prn_cx:
	mov	si, str_cx
	jmp	print_str
.prn_dx:
	mov	si, str_dx
	jmp	print_str
.prn_bx:
	mov	si, str_bx
	jmp	print_str
.prn_sp:
	mov	si, str_spn
	jmp	print_str
.prn_bp:
	mov	si, str_bp
	jmp	print_str
.prn_si:
	mov	si, str_si
	jmp	print_str

print_reg8_name:
	and	al, 7
	cmp	al, 0
	je	.pr8n_al
	cmp	al, 1
	je	.pr8n_cl
	cmp	al, 2
	je	.pr8n_dl
	cmp	al, 3
	je	.pr8n_bl
	cmp	al, 4
	je	.pr8n_ah
	cmp	al, 5
	je	.pr8n_ch
	cmp	al, 6
	je	.pr8n_dh
	mov	si, str_bh
	jmp	print_str
.pr8n_al:
	mov	si, str_al
	jmp	print_str
.pr8n_cl:
	mov	si, str_cl
	jmp	print_str
.pr8n_dl:
	mov	si, str_dl
	jmp	print_str
.pr8n_bl:
	mov	si, str_bl
	jmp	print_str
.pr8n_ah:
	mov	si, str_ah
	jmp	print_str
.pr8n_ch:
	mov	si, str_ch
	jmp	print_str
.pr8n_dh:
	mov	si, str_dh
	jmp	print_str

print_seg_reg_name:
	and	al, 3
	cmp	al, 0
	je	.psrn_es
	cmp	al, 1
	je	.psrn_cs
	cmp	al, 2
	je	.psrn_ss
	mov	si, str_ds
	jmp	print_str
.psrn_es:
	mov	si, str_es
	jmp	print_str
.psrn_cs:
	mov	si, str_cs
	jmp	print_str
.psrn_ss:
	mov	si, str_ss
	jmp	print_str

; ============================================================================
; Messages
; ============================================================================
msg_banner	db	0x0D, 0x0A
		db	'MegaDOS DEBUG 0.2', 0x0D, 0x0A
		db	'Type ? for help.', 0x0D, 0x0A, 0

msg_help	db	0x0D, 0x0A
		db	'A addr ...           Assemble', 0x0D, 0x0A
		db	'BP addr             Set breakpoint', 0x0D, 0x0A
		db	'BL                  List breakpoints', 0x0D, 0x0A
		db	'BC n | *            Clear breakpoint n (or all)', 0x0D, 0x0A
		db	'C start end|L n dst Compare memory', 0x0D, 0x0A
		db	'D [addr [end|L n]]  Dump memory', 0x0D, 0x0A
		db	'E addr bytes...     Enter hex bytes', 0x0D, 0x0A
		db	'F start end|L n byt Fill range', 0x0D, 0x0A
		db	'G [addr]            Go', 0x0D, 0x0A
		db	'H value1 value2     Hex add/subtract', 0x0D, 0x0A
		db	'I port              Read byte from port', 0x0D, 0x0A
		db	'L [file [args]]     Load file (EXE aware)', 0x0D, 0x0A
		db	'M start end|L n dst Move range', 0x0D, 0x0A
		db	'N file [args]       Set file name and target args', 0x0D, 0x0A
		db	'O port byte         Write byte to port', 0x0D, 0x0A
		db	'P [addr]            Proceed', 0x0D, 0x0A
		db	'S start end|L n byt Search byte pattern', 0x0D, 0x0A
		db	'R [reg [value]]     Show/edit target registers', 0x0D, 0x0A
		db	'R F                 Edit flags (OV/NV DN/UP ...)', 0x0D, 0x0A
		db	'T [addr]            Trace', 0x0D, 0x0A
		db	'U [addr [end|L n]]  Unassemble', 0x0D, 0x0A
		db	'W [addr [len]]      Write bytes to current file', 0x0D, 0x0A
		db	'Q                   Quit', 0x0D, 0x0A
		db	'Hex only. Use SEG:OFF for explicit segments.', 0x0D, 0x0A, 0

msg_error	db	'?', 0x0D, 0x0A, 0
msg_bad_range	db	'Bad range', 0x0D, 0x0A, 0
msg_not_found	db	'Not found', 0x0D, 0x0A, 0
msg_no_diff	db	'No differences', 0x0D, 0x0A, 0
msg_no_memory	db	'Not enough memory for target buffer', 0x0D, 0x0A, 0
msg_no_name	db	'No file name', 0x0D, 0x0A, 0
msg_name_set	db	'Name: ', 0
msg_name_cleared	db	'Name cleared', 0x0D, 0x0A, 0
msg_loaded	db	'Loaded bytes: ', 0
msg_written	db	'Wrote bytes: ', 0
msg_too_big	db	'File too large', 0x0D, 0x0A, 0
msg_file_error	db	'File error', 0x0D, 0x0A, 0
msg_stopped	db	'Execution stopped', 0x0D, 0x0A, 0
msg_terminated	db	'Target terminated — reload or set address to resume', 0x0D, 0x0A, 0
msg_not_yet	db	'Not implemented yet', 0x0D, 0x0A, 0
msg_bp_set	db	'BP set', 0x0D, 0x0A, 0
msg_bp_dup	db	'BP already at that address', 0x0D, 0x0A, 0
msg_bp_full	db	'BP table full', 0x0D, 0x0A, 0
msg_bp_none	db	'No breakpoints', 0x0D, 0x0A, 0
msg_bp_cleared	db	'BP cleared', 0x0D, 0x0A, 0
msg_bp_cleared_all	db	'All BPs cleared', 0x0D, 0x0A, 0
msg_bp_notset	db	'BP not set', 0x0D, 0x0A, 0

msg_ax		db	'AX=', 0
msg_bx		db	' BX=', 0
msg_cx		db	' CX=', 0
msg_dx		db	' DX=', 0
msg_si		db	'SI=', 0
msg_di		db	' DI=', 0
msg_bp		db	' BP=', 0
msg_cs		db	'CS=', 0
msg_ds		db	' DS=', 0
msg_es		db	' ES=', 0
msg_ss		db	' SS=', 0
msg_sp		db	' SP=', 0
msg_ip		db	'IP=', 0
msg_fl		db	' FL=', 0
msg_def		db	'DEF=', 0
msg_dump	db	' DUMP=', 0
str_nop		db	'NOP', 0
str_int3	db	'INT3', 0
str_ret		db	'RET', 0
str_retf	db	'RETF', 0
str_iret	db	'IRET', 0
str_int		db	'INT ', 0
str_jmp		db	'JMP ', 0
str_jmp_far	db	'JMP FAR ', 0
str_call	db	'CALL ', 0
str_call_far	db	'CALL FAR ', 0
str_jz		db	'JZ ', 0
str_jnz		db	'JNZ ', 0
str_jo		db	'JO ', 0
str_jno		db	'JNO ', 0
str_jb		db	'JB ', 0
str_jae		db	'JAE ', 0
str_jbe		db	'JBE ', 0
str_ja		db	'JA ', 0
str_js		db	'JS ', 0
str_jns		db	'JNS ', 0
str_jp		db	'JP ', 0
str_jnp		db	'JNP ', 0
str_jl		db	'JL ', 0
str_jge		db	'JGE ', 0
str_jle		db	'JLE ', 0
str_jg		db	'JG ', 0
str_jcxz	db	'JCXZ ', 0
str_loop	db	'LOOP ', 0
str_loope	db	'LOOPE ', 0
str_loopne	db	'LOOPNE ', 0
str_mov		db	'MOV ', 0
str_push	db	'PUSH ', 0
str_pop		db	'POP ', 0
str_inc		db	'INC ', 0
str_dec		db	'DEC ', 0
str_add		db	'ADD ', 0
str_or		db	'OR ', 0
str_adc		db	'ADC ', 0
str_sbb		db	'SBB ', 0
str_and		db	'AND ', 0
str_sub		db	'SUB ', 0
str_xor		db	'XOR ', 0
str_cmp		db	'CMP ', 0
str_test	db	'TEST ', 0
str_xchg	db	'XCHG ', 0
str_not		db	'NOT ', 0
str_neg		db	'NEG ', 0
str_mul		db	'MUL ', 0
str_imul	db	'IMUL ', 0
str_div		db	'DIV ', 0
str_idiv	db	'IDIV ', 0
str_lea		db	'LEA ', 0
str_lds		db	'LDS ', 0
str_les		db	'LES ', 0
str_rol		db	'ROL ', 0
str_ror		db	'ROR ', 0
str_rcl		db	'RCL ', 0
str_rcr		db	'RCR ', 0
str_shl		db	'SHL ', 0
str_shr		db	'SHR ', 0
str_sar		db	'SAR ', 0
str_byte	db	'BYTE ', 0
str_word	db	'WORD ', 0
str_in		db	'IN ', 0
str_out		db	'OUT ', 0
str_ret_sp	db	'RET ', 0
str_retf_sp	db	'RETF ', 0
str_aaa		db	'AAA', 0
str_aas		db	'AAS', 0
str_aad		db	'AAD ', 0
str_aam		db	'AAM ', 0
str_cbw		db	'CBW', 0
str_cwd		db	'CWD', 0
str_daa		db	'DAA', 0
str_das		db	'DAS', 0
str_wait	db	'WAIT', 0
str_pushf	db	'PUSHF', 0
str_popf	db	'POPF', 0
str_sahf	db	'SAHF', 0
str_lahf	db	'LAHF', 0
str_into	db	'INTO', 0
str_lock	db	'LOCK', 0
str_rep		db	'REP', 0
str_repne	db	'REPNE', 0
str_hlt		db	'HLT', 0
str_cmc		db	'CMC', 0
str_clc		db	'CLC', 0
str_stc		db	'STC', 0
str_cli		db	'CLI', 0
str_sti		db	'STI', 0
str_cld		db	'CLD', 0
str_std		db	'STD', 0
str_xlat	db	'XLAT', 0
str_xchg_ax	db	'XCHG AX,', 0
str_movsb	db	'MOVSB', 0
str_movsw	db	'MOVSW', 0
str_cmpsb	db	'CMPSB', 0
str_cmpsw	db	'CMPSW', 0
str_stosb	db	'STOSB', 0
str_stosw	db	'STOSW', 0
str_lodsb	db	'LODSB', 0
str_lodsw	db	'LODSW', 0
str_scasb	db	'SCASB', 0
str_scasw	db	'SCASW', 0
str_add_ax	db	'ADD AX,', 0
str_add_al	db	'ADD AL,', 0
str_sub_ax	db	'SUB AX,', 0
str_sub_al	db	'SUB AL,', 0
str_cmp_ax	db	'CMP AX,', 0
str_cmp_al	db	'CMP AL,', 0
str_db		db	'DB ', 0
str_ax		db	'AX', 0
str_bx		db	'BX', 0
str_cx		db	'CX', 0
str_dx		db	'DX', 0
str_si		db	'SI', 0
str_di		db	'DI', 0
str_bp		db	'BP', 0
str_spn		db	'SP', 0
str_al		db	'AL', 0
str_bl		db	'BL', 0
str_cl		db	'CL', 0
str_dl		db	'DL', 0
str_ah		db	'AH', 0
str_bh		db	'BH', 0
str_ch		db	'CH', 0
str_dh		db	'DH', 0
str_es		db	'ES', 0
str_cs		db	'CS', 0
str_ss		db	'SS', 0
str_ds		db	'DS', 0

; ============================================================================
; Data
; ============================================================================
cmd_buffer:
	db	INPUT_MAX
	db	0
cmd_text:
	times	INPUT_MAX + 2 db 0

psp_seg		dw	0
target_seg	dw	0
default_seg	dw	0
last_dump_seg	dw	0
last_dump_off	dw	0

target_ax	dw	0
target_bx	dw	0
target_cx	dw	0
target_dx	dw	0
target_si	dw	0
target_di	dw	0
target_bp	dw	0
target_ip	dw	0
target_sp	dw	0
target_flags	dw	0
target_cs	dw	0
target_ds	dw	0
target_es	dw	0
target_ss	dw	0
target_loaded	db	0

work_seg		dw	0
work_start	dw	0
work_end		dw	0
line_off		dw	0

dest_seg		dw	0
dest_off		dw	0
move_len		dw	0
copy_backward	db	0

max_start	dw	0
fill_byte	db	0
found_any	db	0
search_len	db	0
search_bytes	times SEARCH_MAX db 0
diff_found	db	0
compare_src_byte	db	0
compare_dst_byte	db	0
math_left	dw	0
math_right	dw	0
reg_ptr		dw	0
reg_name_ptr	dw	0
reg_size	db	0		; 1 = byte register, 2 = word register

file_name_set	db	0
file_name	times FNAME_MAX + 1 db 0
file_handle	dw	0
file_size	dw	0
file_size_hi	dw	0		; high word of 32-bit file size
saved_dta_off	dw	0		; DEBUG's DTA saved across target runs
saved_dta_seg	dw	0
target_dta_off	dw	0		; Target's remembered DTA (survives stops)
target_dta_seg	dw	0
target_terminated db	0		; 1 = target hit INT 20 / AH=00 / 31 / 4C

run_mode	db	0
stop_reason	db	0
debugger_ss	dw	0
debugger_sp	dw	0
old_int1_off	dw	0
old_int1_seg	dw	0
old_int3_off	dw	0
old_int3_seg	dw	0
old_int20_off	dw	0
old_int20_seg	dw	0
old_int21_off	dw	0
old_int21_seg	dw	0

opcode_byte	db	0
asm_accum_kind	db	0
asm_reg_code	db	0
asm_reg_width	db	0
asm_src_code	db	0
asm_alu_group	db	0
asm_alu_reg_op	db	0
asm_alu_acc_op	db	0
asm_opcode	db	0
asm_seg_code	db	0
asm_modrm	db	0
asm_instr_len	db	0
asm_mem_width	db	0
asm_mem_mod	db	0
asm_mem_rm	db	0
asm_mem_disp_size	db	0
asm_mem_disp	dw	0
asm_ea_mask	db	0
asm_ea_seen	db	0
asm_ea_sign	db	0
asm_imm_word	dw	0
asm_seg_override db	0		; 0 or 0x26/0x2E/0x36/0x3E (segment override prefix byte)
disasm_seg_override db	0	; 0 or 0x26/0x2E/0x36/0x3E (active prefix during U)
disasm_rep_prefix db	0	; 0 or 0xF0/0xF2/0xF3 (active LOCK/REPNE/REP during U)

; Temp breakpoint state for P (proceed/step-over)
temp_break_active	db	0
temp_break_seg		dw	0
temp_break_off		dw	0
temp_break_orig		db	0

; User breakpoint table
bp_table:	times BP_COUNT * BP_SIZE db 0
bp_list_any	db	0
bp_skip_pending	db	0		; 1 = int1_handler should re-install BPs and continue
bp_install_force db	0		; 1 = install every active BP even at current IP

u_end_off	dw	0		; U command: inclusive end offset

w_seg		dw	0		; W command: source segment
w_off		dw	0		; W command: source offset
w_len		dw	0		; W command: byte count

exe_header	times 28 db 0		; First 28 bytes of an EXE MZ header
exe_load_seg	dw	0		; Segment at which EXE code is loaded
exe_code_size	dw	0		; Code portion size (file minus header)
exe_hdr_bytes	dw	0		; Header size in bytes
exe_reloc_count	dw	0		; Remaining relocation entries
reloc_entry	dw	0, 0		; Current (offset, segment) from reloc table

end_of_prog:
