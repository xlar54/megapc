; DIRTEST.COM — tests FindFirst/FindNext, CHDIR, delete, create dir, attrs
; Usage: DIRTEST [pattern]  (default: *.*)
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; === Test AH=0E: Set drive (set to A:) ===
	mov	si, msg_setdrv
	call	print_str
	mov	ah, 0x0E
	mov	dl, 0		; Drive A
	int	0x21
	push	ax
	mov	al, ah		; original AH is gone, AL = num drives
	pop	ax
	xor	ah, ah
	call	print_dec
	mov	si, msg_drives
	call	print_str
	call	newline

	; === Test AH=43: Get file attributes ===
	mov	si, msg_attr
	call	print_str
	mov	ax, 0x4300
	mov	dx, fname_shell
	int	0x21
	jc	.attr_err
	mov	ax, cx
	call	print_hex
	call	newline
	jmp	.attr_done
.attr_err:
	mov	si, msg_err
	call	print_str
	call	newline
.attr_done:

	; === Test AH=57: Get file time ===
	; First open a file
	mov	si, msg_ftime
	call	print_str
	mov	ax, 0x3D00		; Open read-only
	mov	dx, fname_shell
	int	0x21
	jc	.ftime_err
	mov	bx, ax			; Handle
	mov	ax, 0x5700		; Get file time
	int	0x21
	jc	.ftime_err
	; CX=time, DX=date
	mov	ax, dx
	call	print_hex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	ax, cx
	call	print_hex
	call	newline
	; Close file
	mov	ah, 0x3E
	int	0x21
	jmp	.ftime_done
.ftime_err:
	mov	si, msg_err
	call	print_str
	call	newline
.ftime_done:

	; === Test AH=29: Parse filename ===
	mov	si, msg_parse
	call	print_str
	mov	si, parse_input
	push	es
	push	cs
	pop	es
	mov	di, fcb_buf
	mov	ah, 0x29
	int	0x21
	pop	es
	; Print FCB drive
	push	ax
	mov	al, [fcb_buf]
	xor	ah, ah
	call	print_dec
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	; Print FCB name (11 chars)
	mov	si, fcb_buf + 1
	mov	cx, 11
.parse_print:
	lodsb
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.parse_print
	pop	ax
	; Print return code
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, '('
	mov	ah, 0x02
	int	0x21
	xor	ah, ah
	call	print_dec
	mov	dl, ')'
	mov	ah, 0x02
	int	0x21
	call	newline

	; === Test AH=4E/4F: FindFirst/FindNext ===
	mov	si, msg_find
	call	print_str
	call	newline

	; Determine search pattern: use command tail or default *.*
	mov	si, 0x80		; PSP command tail length
	mov	cl, [si]
	xor	ch, ch
	cmp	cx, 0
	je	.use_default
	; Skip leading space
	mov	si, 0x81
.skip_space:
	cmp	byte [si], ' '
	jne	.got_pattern
	inc	si
	dec	cx
	jnz	.skip_space
.use_default:
	mov	dx, default_pat
	jmp	.do_find
.got_pattern:
	; Copy to pattern buffer and null-terminate
	mov	di, pat_buf
	mov	dx, di
.copy_pat:
	lodsb
	cmp	al, 0x0D
	je	.pat_done
	cmp	al, ' '
	je	.pat_done
	cmp	al, 0
	je	.pat_done
	stosb
	dec	cx
	jnz	.copy_pat
.pat_done:
	mov	byte [di], 0
	mov	dx, pat_buf

.do_find:
	; Save DX (pattern pointer) — print_str clobbers DL
	push	dx
	mov	si, msg_pattern
	call	print_str
	pop	dx
	push	dx
	mov	si, dx
	call	print_str
	call	newline
	call	newline
	pop	dx

	; FindFirst
	mov	cx, 0x37		; All attributes
	mov	ah, 0x4E
	int	0x21
	jc	.find_none

.find_loop:
	; DTA is at PSP:0080 by default
	; Print: attr, size, name
	mov	si, 0x80		; DTA base

	; Attribute at +21
	mov	al, [si+21]
	push	ax
	xor	ah, ah
	call	print_hex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax

	; Check if directory
	test	al, 0x10
	jz	.not_dir
	mov	si, msg_dir_tag2
	call	print_str
	jmp	.print_name
.not_dir:
	; Size at +26 (4 bytes, print low 16)
	mov	si, 0x80
	mov	ax, [si+26]
	call	print_dec
	; Pad to 8 chars
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

.print_name:
	; Name at +30 (ASCIIZ)
	mov	si, 0x80 + 30
	call	print_str
	call	newline

	; FindNext
	mov	ah, 0x4F
	int	0x21
	jnc	.find_loop

	call	newline
	mov	si, msg_done
	call	print_str
	call	newline

	mov	ax, 0x4C00
	int	0x21

.find_none:
	mov	si, msg_nofiles
	call	print_str
	call	newline
	mov	ax, 0x4C00
	int	0x21

; --- Subroutines ---
print_str:
	push	ax
.ps_loop:
	lodsb
	or	al, al
	jz	.ps_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.ps_loop
.ps_done:
	pop	ax
	ret

newline:
	push	ax
	push	dx
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	pop	dx
	pop	ax
	ret

print_dec:
	push	ax
	push	bx
	push	cx
	push	dx
	xor	cx, cx
	mov	bx, 10
.pd_div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_div
.pd_print:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pd_print
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

print_hex:
	push	ax
	push	cx
	push	dx
	mov	cx, 4
.ph_loop:
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.ph_ok
	add	al, 7
.ph_ok:
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph_loop
	pop	dx
	pop	cx
	pop	ax
	ret

; --- Data ---
msg_setdrv	db	'Set Drive A: num drives=', 0
msg_drives	db	0
msg_attr	db	'SHELL.COM attrs: ', 0
msg_ftime	db	'SHELL.COM time: ', 0
msg_parse	db	'Parse "B:TEST.TXT": ', 0
msg_find	db	'--- FindFirst/FindNext ---', 0
msg_pattern	db	'Pattern: ', 0
msg_dir_tag2	db	'<DIR>  ', 0
msg_nofiles	db	'No files found.', 0
msg_done	db	'Search complete.', 0
msg_err		db	'ERROR', 0

fname_shell	db	'SHELL.COM', 0
parse_input	db	'B:TEST.TXT', 0
default_pat	db	'*.*', 0
pat_buf		times 20 db 0
fcb_buf		times 37 db 0
