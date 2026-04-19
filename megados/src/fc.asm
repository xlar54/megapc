; FC.COM — File Compare
; Usage: FC [/B] [/I] file1 file2
;   /B = binary comparison (byte by byte)
;   /I = case-insensitive (text mode only)
;   Default: text (line by line) comparison
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
	mov	byte [opt_bin], 0
	mov	byte [opt_icase], 0

	; Parse switches
.parse_sw:
	call	skip_sp
	cmp	byte [si], '/'
	jne	.parse_files
	inc	si
	mov	al, [si]
	or	al, 0x20
	cmp	al, 'b'
	je	.sw_bin
	cmp	al, 'i'
	je	.sw_icase
	jmp	usage
.sw_bin:
	mov	byte [opt_bin], 1
	inc	si
	jmp	.parse_sw
.sw_icase:
	mov	byte [opt_icase], 1
	inc	si
	jmp	.parse_sw

.parse_files:
	; First filename
	call	skip_sp
	cmp	byte [si], 0x0D
	je	usage
	cmp	byte [si], 0
	je	usage
	mov	di, fname1
	call	copy_fname

	; Second filename
	call	skip_sp
	cmp	byte [si], 0x0D
	je	usage
	cmp	byte [si], 0
	je	usage
	mov	di, fname2
	call	copy_fname

	; Open both files
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname1
	int	0x21
	jc	err_file1
	mov	[handle1], ax

	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname2
	int	0x21
	jc	err_file2
	mov	[handle2], ax

	; Dispatch to binary or text compare
	cmp	byte [opt_bin], 1
	je	do_binary

	; ============================================================
	; Text comparison — line by line
	; ============================================================
do_text:
	; Print header
	mov	si, msg_comparing
	call	pstr
	mov	si, fname1
	call	pstr
	mov	si, msg_and
	call	pstr
	mov	si, fname2
	call	pstr
	call	crlf

	mov	word [line_num], 0
	mov	byte [diff_found], 0

.text_loop:
	inc	word [line_num]

	; Read line from file 1
	mov	bx, [handle1]
	mov	di, line1
	call	read_line
	mov	[eof1], al		; AL=1 if EOF

	; Read line from file 2
	mov	bx, [handle2]
	mov	di, line2
	call	read_line
	mov	[eof2], al

	; Both EOF?
	cmp	byte [eof1], 1
	jne	.not_both_eof
	cmp	byte [eof2], 1
	je	.text_done
.not_both_eof:

	; Compare lines
	mov	si, line1
	mov	di, line2
	call	compare_lines
	je	.text_match

	; Lines differ — print them
	mov	byte [diff_found], 1
	; Print file1 line
	mov	si, fname1
	call	pstr
	mov	al, '('
	call	putch
	mov	ax, [line_num]
	call	pdec
	mov	al, ')'
	call	putch
	mov	al, ':'
	call	putch
	mov	al, ' '
	call	putch
	mov	si, line1
	call	pstr
	call	crlf
	; Print file2 line
	mov	si, fname2
	call	pstr
	mov	al, '('
	call	putch
	mov	ax, [line_num]
	call	pdec
	mov	al, ')'
	call	putch
	mov	al, ':'
	call	putch
	mov	al, ' '
	call	putch
	mov	si, line2
	call	pstr
	call	crlf

.text_match:
	; Check if either file ended
	cmp	byte [eof1], 1
	je	.file1_ended
	cmp	byte [eof2], 1
	je	.file2_ended
	jmp	.text_loop

.file1_ended:
	cmp	byte [eof2], 1
	je	.text_done
	; File 2 has more lines
	mov	byte [diff_found], 1
	mov	si, msg_file2_longer
	call	pstr
	jmp	.text_done

.file2_ended:
	; File 1 has more lines
	mov	byte [diff_found], 1
	mov	si, msg_file1_longer
	call	pstr

.text_done:
	cmp	byte [diff_found], 0
	jne	.text_exit
	mov	si, msg_no_diff
	call	pstr
.text_exit:
	jmp	close_exit

	; ============================================================
	; Binary comparison — byte by byte
	; ============================================================
do_binary:
	; Print header
	mov	si, msg_comparing
	call	pstr
	mov	si, fname1
	call	pstr
	mov	si, msg_and
	call	pstr
	mov	si, fname2
	call	pstr
	call	crlf

	mov	word [offset_lo], 0
	mov	word [offset_hi], 0
	mov	byte [diff_found], 0

.bin_loop:
	; Read one byte from each file
	mov	ah, 0x3F
	mov	bx, [handle1]
	mov	cx, 1
	mov	dx, byte1
	int	0x21
	mov	[read1], ax		; 0 = EOF

	mov	ah, 0x3F
	mov	bx, [handle2]
	mov	cx, 1
	mov	dx, byte2
	int	0x21
	mov	[read2], ax

	; Both EOF?
	cmp	word [read1], 0
	jne	.bin_not_eof
	cmp	word [read2], 0
	je	.bin_done
.bin_not_eof:

	; One EOF?
	cmp	word [read1], 0
	je	.bin_file1_short
	cmp	word [read2], 0
	je	.bin_file2_short

	; Compare bytes
	mov	al, [byte1]
	cmp	al, [byte2]
	je	.bin_match

	; Difference found — print offset and bytes
	mov	byte [diff_found], 1
	mov	ax, [offset_lo]
	mov	dx, [offset_hi]
	call	phex32
	mov	al, ':'
	call	putch
	mov	al, ' '
	call	putch
	mov	al, [byte1]
	call	phex8
	mov	al, ' '
	call	putch
	mov	al, [byte2]
	call	phex8
	call	crlf

.bin_match:
	; Advance offset
	inc	word [offset_lo]
	jnz	.bin_loop
	inc	word [offset_hi]
	jmp	.bin_loop

.bin_file1_short:
	mov	byte [diff_found], 1
	mov	si, msg_file1_shorter
	call	pstr
	jmp	.bin_done

.bin_file2_short:
	mov	byte [diff_found], 1
	mov	si, msg_file2_shorter
	call	pstr

.bin_done:
	cmp	byte [diff_found], 0
	jne	close_exit
	mov	si, msg_no_diff
	call	pstr

close_exit:
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	mov	ah, 0x3E
	mov	bx, [handle2]
	int	0x21
	mov	ax, 0x4C00
	int	0x21

err_file1:
	mov	si, msg_err_open1
	call	pstr
	mov	ax, 0x4C01
	int	0x21

err_file2:
	; Close file 1 first
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	mov	si, msg_err_open2
	call	pstr
	mov	ax, 0x4C01
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

; ============================================================================
; read_line — Read one line from file handle BX into ES:DI
; Returns: AL=1 if EOF (no data read), AL=0 if line read
; Null-terminates the line.
; ============================================================================
read_line:
	push	bx
	push	cx
	push	dx
	xor	cx, cx			; Line length
.rl_char:
	push	cx
	push	di
	push	bx
	mov	ah, 0x3F
	mov	cx, 1
	mov	dx, char_buf
	int	0x21
	pop	bx
	pop	di
	pop	cx
	cmp	ax, 0			; EOF
	je	.rl_eof
	mov	al, [char_buf]
	cmp	al, 0x0A		; LF
	je	.rl_done
	cmp	al, 0x0D		; CR — skip
	je	.rl_char
	cmp	al, 0x1A		; Ctrl-Z
	je	.rl_eof
	cmp	cx, MAX_LINE
	jae	.rl_char		; Too long
	stosb
	inc	cx
	jmp	.rl_char
.rl_eof:
	cmp	cx, 0
	je	.rl_is_eof
.rl_done:
	mov	byte [di], 0
	mov	al, 0			; Not EOF
	pop	dx
	pop	cx
	pop	bx
	ret
.rl_is_eof:
	mov	byte [di], 0
	mov	al, 1			; EOF
	pop	dx
	pop	cx
	pop	bx
	ret

; ============================================================================
; compare_lines — Compare null-terminated strings at SI and DI
; Returns: ZF=1 if equal, ZF=0 if different
; ============================================================================
compare_lines:
	push	si
	push	di
.cl_loop:
	lodsb
	mov	ah, [di]
	inc	di
	; Case-insensitive?
	cmp	byte [opt_icase], 1
	jne	.cl_exact
	cmp	al, 'a'
	jb	.cl_up_ah
	cmp	al, 'z'
	ja	.cl_up_ah
	sub	al, 0x20
.cl_up_ah:
	cmp	ah, 'a'
	jb	.cl_exact
	cmp	ah, 'z'
	ja	.cl_exact
	sub	ah, 0x20
.cl_exact:
	cmp	al, ah
	jne	.cl_diff
	or	al, al			; Both null?
	jnz	.cl_loop
	; Equal
	pop	di
	pop	si
	ret				; ZF=1
.cl_diff:
	or	al, 1			; Clear ZF
	pop	di
	pop	si
	ret				; ZF=0

; ============================================================================
; copy_fname — Copy filename from SI to DI, null-terminate, advance SI
; ============================================================================
copy_fname:
	mov	al, [si]
	cmp	al, 0x0D
	je	.cf_done
	cmp	al, 0
	je	.cf_done
	cmp	al, ' '
	je	.cf_done
	stosb
	inc	si
	jmp	copy_fname
.cf_done:
	mov	byte [di], 0
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

; phex32 — Print DX:AX as 8-digit hex
phex32:
	push	ax
	mov	al, dh
	call	phex8
	mov	al, dl
	call	phex8
	pop	ax
	push	ax
	mov	al, ah
	call	phex8
	pop	ax
	call	phex8
	ret

; phex8 — Print AL as 2-digit hex
phex8:
	push	ax
	shr	al, 1
	shr	al, 1
	shr	al, 1
	shr	al, 1
	call	.hex_nib
	pop	ax
	and	al, 0x0F
	call	.hex_nib
	ret
.hex_nib:
	cmp	al, 10
	jb	.hex_digit
	add	al, 'A' - 10
	jmp	.hex_out
.hex_digit:
	add	al, '0'
.hex_out:
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	ret

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: FC [/B] [/I] file1 file2', 0x0D, 0x0A, 0
msg_comparing	db	'Comparing ', 0
msg_and		db	' and ', 0
msg_no_diff	db	'FC: no differences encountered', 0x0D, 0x0A, 0
msg_file1_longer db	'FC: file1 is longer', 0x0D, 0x0A, 0
msg_file2_longer db	'FC: file2 is longer', 0x0D, 0x0A, 0
msg_file1_shorter db	'FC: file1 is shorter', 0x0D, 0x0A, 0
msg_file2_shorter db	'FC: file2 is shorter', 0x0D, 0x0A, 0
msg_err_open1	db	'Cannot open first file', 0x0D, 0x0A, 0
msg_err_open2	db	'Cannot open second file', 0x0D, 0x0A, 0

; ============================================================================
; Data
; ============================================================================
opt_bin		db	0
opt_icase	db	0
diff_found	db	0
handle1		dw	0
handle2		dw	0
eof1		db	0
eof2		db	0
read1		dw	0
read2		dw	0
offset_lo	dw	0
offset_hi	dw	0
line_num	dw	0
byte1		db	0
byte2		db	0
char_buf	db	0

fname1		times 128 db 0
fname2		times 128 db 0
line1		times 256 db 0
line2		times 256 db 0
