; MORE.COM — Display output one screen at a time
; Usage: MORE < file.txt   (via stdin redirection)
;        MORE file.txt     (direct file argument)
	cpu	8086
	org	0x0100

LINES_PER_PAGE	equ	23

start:
	; Check for filename argument on command line
	mov	si, 0x0081
	call	skip_sp
	cmp	byte [si], 0x0D
	je	.use_stdin
	cmp	byte [si], 0
	je	.use_stdin

	; Open file from command line
	; Copy filename to fname buffer (strip trailing CR)
	mov	di, fname
.copy_fname:
	lodsb
	cmp	al, 0x0D
	je	.fname_done
	cmp	al, ' '
	je	.fname_done
	cmp	al, 0
	je	.fname_done
	mov	[di], al
	inc	di
	jmp	.copy_fname
.fname_done:
	mov	byte [di], 0

	; Open file
	mov	ah, 0x3D
	mov	al, 0		; Read only
	mov	dx, fname
	int	0x21
	jc	.file_err
	mov	[handle], ax
	jmp	.read_loop

.use_stdin:
	; Read from stdin (handle 0)
	mov	word [handle], 0

.read_loop:
	mov	byte [line_count], 0

.page_loop:
	; Read and display one line
	call	read_line
	jc	.eof		; EOF or error

	; Print the line
	mov	si, linebuf
	call	print_str
	; Print CR/LF
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21

	inc	byte [line_count]
	cmp	byte [line_count], LINES_PER_PAGE
	jb	.page_loop

	; Show "-- More --" prompt and wait for key
	mov	si, more_msg
	call	print_str
	mov	ah, 0x08	; Wait for key (no echo)
	int	0x21

	; Erase the prompt
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	si, blank_msg
	call	print_str
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21

	; Check if user pressed Q to quit
	cmp	al, 'q'
	je	.done
	cmp	al, 'Q'
	je	.done

	jmp	.read_loop

.eof:
	; Close file if not stdin
	cmp	word [handle], 0
	je	.done
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
.done:
	mov	ax, 0x4C00
	int	0x21

.file_err:
	mov	si, err_msg
	call	print_str
	mov	ax, 0x4C01
	int	0x21

; ============================================================================
; read_line: read one line from [handle] into linebuf
; Returns: CF=0 success, CF=1 EOF
; ============================================================================
read_line:
	mov	di, linebuf
	mov	cx, 255		; Max line length
.rl_char:
	push	cx
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1
	mov	dx, charbuf
	int	0x21
	pop	cx
	cmp	ax, 0		; EOF
	je	.rl_eof
	mov	al, [charbuf]
	cmp	al, 0x0A	; LF = end of line
	je	.rl_done
	cmp	al, 0x0D	; CR = skip
	je	.rl_char
	cmp	al, 0x1A	; Ctrl-Z = EOF
	je	.rl_eof
	mov	[di], al
	inc	di
	dec	cx
	jnz	.rl_char
.rl_done:
	mov	byte [di], 0
	clc
	ret
.rl_eof:
	; If we have partial data, return it
	cmp	di, linebuf
	je	.rl_eof_empty
	mov	byte [di], 0
	clc
	ret
.rl_eof_empty:
	stc
	ret

; ============================================================================
; Helpers
; ============================================================================
skip_sp:
	cmp	byte [si], ' '
	jne	.ss_done
	inc	si
	jmp	skip_sp
.ss_done:
	ret

print_str:
	lodsb
	or	al, al
	jz	.ps_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	print_str
.ps_done:
	ret

; ============================================================================
; Data
; ============================================================================
more_msg	db	'-- More --', 0
blank_msg	db	'          ', 0
err_msg		db	'File not found', 0x0D, 0x0A, 0

handle		dw	0
line_count	db	0
charbuf		db	0
fname		times 78 db 0
linebuf		times 256 db 0
