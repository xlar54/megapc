; ATTRIB.COM — Display or change file attributes
; Usage: ATTRIB [+R|-R] [+H|-H] [+S|-S] [+A|-A] filename
;   No flags: display current attributes
;   +X: set attribute, -X: clear attribute
	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	; Parse command line
	mov	si, 0x0081
	call	skip_sp
	cmp	byte [si], 0x0D
	je	usage
	cmp	byte [si], 0
	je	usage

	; Parse attribute flags and filename
	mov	byte [set_mask], 0	; Bits to set
	mov	byte [clr_mask], 0	; Bits to clear
	mov	byte [have_flags], 0

.parse_loop:
	call	skip_sp
	cmp	byte [si], 0x0D
	je	.parse_done
	cmp	byte [si], 0
	je	.parse_done
	cmp	byte [si], '+'
	je	.set_flag
	cmp	byte [si], '-'
	je	.clr_flag
	jmp	.parse_fname

.set_flag:
	inc	si
	call	.get_attr_bit
	jc	usage
	or	[set_mask], al
	mov	byte [have_flags], 1
	inc	si
	jmp	.parse_loop

.clr_flag:
	inc	si
	call	.get_attr_bit
	jc	usage
	or	[clr_mask], al
	mov	byte [have_flags], 1
	inc	si
	jmp	.parse_loop

; Map letter at [si] to attribute bit in AL. CF=1 if invalid.
.get_attr_bit:
	mov	al, [si]
	or	al, 0x20		; Lowercase
	cmp	al, 'r'
	je	.bit_r
	cmp	al, 'h'
	je	.bit_h
	cmp	al, 's'
	je	.bit_s
	cmp	al, 'a'
	je	.bit_a
	stc
	ret
.bit_r:
	mov	al, 0x01
	ret
.bit_h:
	mov	al, 0x02
	ret
.bit_s:
	mov	al, 0x04
	ret
.bit_a:
	mov	al, 0x20
	ret

.parse_fname:
	; Copy filename to fname buffer (null-terminate)
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

.parse_done:
	; Must have a filename
	cmp	byte [fname], 0
	je	usage

	cmp	byte [have_flags], 0
	je	.show_attrs

	; --- Set/clear attributes ---
	; Get current attributes first
	mov	ax, 0x4300
	mov	dx, fname
	int	0x21
	jc	.file_err
	; CX = current attributes
	; Apply changes
	or	cl, [set_mask]
	mov	al, [clr_mask]
	not	al
	and	cl, al
	; Set new attributes
	mov	ax, 0x4301
	mov	dx, fname
	int	0x21
	jc	.file_err
	jmp	exit

.show_attrs:
	; Get attributes
	mov	ax, 0x4300
	mov	dx, fname
	int	0x21
	jc	.file_err
	; CL = attributes
	; Print attribute letters
	test	cl, 0x20
	jz	.no_a
	mov	dl, 'A'
	jmp	.print_a
.no_a:
	mov	dl, ' '
.print_a:
	mov	ah, 0x02
	int	0x21

	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	test	cl, 0x04
	jz	.no_s
	mov	dl, 'S'
	jmp	.print_s
.no_s:
	mov	dl, ' '
.print_s:
	mov	ah, 0x02
	int	0x21

	test	cl, 0x02
	jz	.no_h
	mov	dl, 'H'
	jmp	.print_h
.no_h:
	mov	dl, ' '
.print_h:
	mov	ah, 0x02
	int	0x21

	test	cl, 0x01
	jz	.no_r
	mov	dl, 'R'
	jmp	.print_r
.no_r:
	mov	dl, ' '
.print_r:
	mov	ah, 0x02
	int	0x21

	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; Print filename
	mov	si, fname
.print_fname:
	lodsb
	or	al, al
	jz	.print_fname_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.print_fname
.print_fname_done:
	call	crlf
	jmp	exit

.file_err:
	mov	si, msg_not_found
	call	pstr
	mov	ax, 0x4C01
	int	0x21

exit:
	mov	ax, 0x4C00
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

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

crlf:
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	ret

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: ATTRIB [+R|-R] [+H|-H] [+S|-S] [+A|-A] file', 0x0D, 0x0A, 0
msg_not_found	db	'File not found', 0x0D, 0x0A, 0

; ============================================================================
; Data
; ============================================================================
set_mask	db	0
clr_mask	db	0
have_flags	db	0
fname		times 128 db 0
