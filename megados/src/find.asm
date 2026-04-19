; FIND.COM — Search for a text string in a file
; Usage: FIND [/I] [/C] [/N] [/V] "string" filename
;   /I = case-insensitive
;   /C = count matches only
;   /N = show line numbers
;   /V = show lines NOT containing string
	cpu	8086
	org	0x0100

MAX_LINE	equ	255

start:
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	; Parse command line
	mov	si, 0x0081
	mov	byte [opt_i], 0
	mov	byte [opt_c], 0
	mov	byte [opt_n], 0
	mov	byte [opt_v], 0

	; Parse switches
.parse_sw:
	call	skip_sp
	cmp	byte [si], '/'
	jne	.parse_string
	inc	si
	mov	al, [si]
	or	al, 0x20
	cmp	al, 'i'
	je	.sw_i
	cmp	al, 'c'
	je	.sw_c
	cmp	al, 'n'
	je	.sw_n
	cmp	al, 'v'
	je	.sw_v
	jmp	usage
.sw_i:
	mov	byte [opt_i], 1
	inc	si
	jmp	.parse_sw
.sw_c:
	mov	byte [opt_c], 1
	inc	si
	jmp	.parse_sw
.sw_n:
	mov	byte [opt_n], 1
	inc	si
	jmp	.parse_sw
.sw_v:
	mov	byte [opt_v], 1
	inc	si
	jmp	.parse_sw

.parse_string:
	; Expect quoted string
	call	skip_sp
	cmp	byte [si], '"'
	jne	usage
	inc	si
	; Copy search string
	mov	di, search_str
	xor	cx, cx
.copy_str:
	mov	al, [si]
	cmp	al, '"'
	je	.str_done
	cmp	al, 0x0D
	je	usage		; No closing quote
	cmp	al, 0
	je	usage
	stosb
	inc	si
	inc	cx
	cmp	cx, 128
	jb	.copy_str
.str_done:
	mov	byte [di], 0
	mov	[search_len], cx
	inc	si		; Skip closing quote

	; Parse filename
	call	skip_sp
	cmp	byte [si], 0x0D
	je	usage
	cmp	byte [si], 0
	je	usage
	mov	di, fname
.copy_fname:
	mov	al, [si]
	cmp	al, 0x0D
	je	.fname_done
	cmp	al, 0
	je	.fname_done
	cmp	al, ' '
	je	.fname_done
	stosb
	inc	si
	jmp	.copy_fname
.fname_done:
	mov	byte [di], 0

	; Open file
	mov	ah, 0x3D
	mov	al, 0		; Read only
	mov	dx, fname
	int	0x21
	jc	file_err
	mov	[handle], ax

	; Print header
	mov	si, msg_header
	call	pstr
	mov	si, fname
	call	pstr
	call	crlf

	; Process file line by line
	mov	word [line_num], 0
	mov	word [match_count], 0

.read_line:
	; Read one line into line_buf
	mov	di, line_buf
	xor	cx, cx		; Line length
.read_char:
	push	cx
	push	di
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1
	mov	dx, char_buf
	int	0x21
	pop	di
	pop	cx
	cmp	ax, 0		; EOF
	je	.eof
	mov	al, [char_buf]
	cmp	al, 0x0A	; LF = end of line
	je	.got_line
	cmp	al, 0x0D	; CR = skip
	je	.read_char
	cmp	al, 0x1A	; Ctrl-Z = EOF
	je	.eof
	cmp	cx, MAX_LINE
	jae	.read_char	; Line too long, skip extra
	stosb
	inc	cx
	jmp	.read_char

.got_line:
	mov	byte [di], 0	; Null-terminate
	mov	[line_len], cx
	inc	word [line_num]

	; Search for string in line
	call	search_line
	; AL = 1 if found, 0 if not

	; Apply /V (invert)
	cmp	byte [opt_v], 1
	jne	.no_invert
	xor	al, 1
.no_invert:

	cmp	al, 1
	jne	.read_line	; No match

	; Match found
	inc	word [match_count]

	; If /C, don't print lines
	cmp	byte [opt_c], 1
	je	.read_line

	; Print line number if /N
	cmp	byte [opt_n], 1
	jne	.no_linenum
	mov	al, '['
	call	putch
	mov	ax, [line_num]
	call	pdec
	mov	al, ']'
	call	putch
.no_linenum:
	; Print the line
	mov	si, line_buf
.print_line:
	lodsb
	or	al, al
	jz	.print_line_done
	call	putch
	jmp	.print_line
.print_line_done:
	call	crlf
	jmp	.read_line

.eof:
	; Process any partial last line
	cmp	cx, 0
	je	.eof_done
	mov	byte [di], 0
	mov	[line_len], cx
	inc	word [line_num]
	call	search_line
	cmp	byte [opt_v], 1
	jne	.eof_no_inv
	xor	al, 1
.eof_no_inv:
	cmp	al, 1
	jne	.eof_done
	inc	word [match_count]
	cmp	byte [opt_c], 1
	je	.eof_done
	cmp	byte [opt_n], 1
	jne	.eof_no_ln
	mov	al, '['
	call	putch
	mov	ax, [line_num]
	call	pdec
	mov	al, ']'
	call	putch
.eof_no_ln:
	mov	si, line_buf
.eof_print:
	lodsb
	or	al, al
	jz	.eof_done
	call	putch
	jmp	.eof_print

.eof_done:
	; Close file
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	; If /C, print count
	cmp	byte [opt_c], 1
	jne	exit
	mov	si, msg_count
	call	pstr
	mov	ax, [match_count]
	call	pdec
	call	crlf

exit:
	mov	ax, 0x4C00
	int	0x21

file_err:
	mov	si, msg_file_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

; ============================================================================
; search_line — Search for search_str in line_buf
; Returns: AL=1 if found, AL=0 if not
; ============================================================================
search_line:
	push	bx
	push	cx
	push	si
	push	di

	mov	cx, [line_len]
	mov	bx, [search_len]
	cmp	cx, bx
	jb	.sl_not_found	; Line shorter than search string

	sub	cx, bx
	inc	cx		; Number of positions to try
	mov	si, line_buf

.sl_try:
	push	si
	push	cx
	mov	di, search_str
	mov	cx, bx		; Search string length
.sl_cmp:
	lodsb
	mov	ah, [di]
	inc	di
	; Case-insensitive if /I
	cmp	byte [opt_i], 1
	jne	.sl_exact
	; Uppercase both
	cmp	al, 'a'
	jb	.sl_up_ah
	cmp	al, 'z'
	ja	.sl_up_ah
	sub	al, 0x20
.sl_up_ah:
	cmp	ah, 'a'
	jb	.sl_compare
	cmp	ah, 'z'
	ja	.sl_compare
	sub	ah, 0x20
	jmp	.sl_compare
.sl_exact:
.sl_compare:
	cmp	al, ah
	jne	.sl_no_match
	dec	cx
	jnz	.sl_cmp
	; Full match
	pop	cx
	pop	si
	mov	al, 1
	jmp	.sl_done

.sl_no_match:
	pop	cx
	pop	si
	inc	si
	dec	cx
	jnz	.sl_try

.sl_not_found:
	mov	al, 0
.sl_done:
	pop	di
	pop	si
	pop	cx
	pop	bx
	ret

; ============================================================================
; Helpers
; ============================================================================
skip_sp:
	cmp	byte [si], ' '
	jne	.done
	inc	si
	jmp	skip_sp
.done:
	ret

pstr:
	lodsb
	or	al, al
	jz	.done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	pstr
.done:
	ret

putch:
	push	ax
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	ret

crlf:
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	ret

pdec:
	push	cx
	push	dx
	push	bx
	xor	cx, cx
	mov	bx, 10
.div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.div
.pr:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pr
	pop	bx
	pop	dx
	pop	cx
	ret

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: FIND [/I] [/C] [/N] [/V] "string" filename', 0x0D, 0x0A, 0
msg_file_err	db	'File not found', 0x0D, 0x0A, 0
msg_header	db	0x0D, 0x0A, '---------- ', 0
msg_count	db	'Count: ', 0

; ============================================================================
; Data
; ============================================================================
opt_i		db	0
opt_c		db	0
opt_n		db	0
opt_v		db	0
handle		dw	0
line_num	dw	0
match_count	dw	0
search_len	dw	0
line_len	dw	0
char_buf	db	0

search_str	times 129 db 0
fname		times 128 db 0
line_buf	times 256 db 0
