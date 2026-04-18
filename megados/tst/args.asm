; ARGS.COM — prints its command line arguments
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Print label
	mov	si, msg
	call	pstr

	; Get command tail length from PSP:0x80
	mov	cl, [0x80]
	xor	ch, ch
	jcxz	.no_args

	; Print command tail from PSP:0x81
	mov	si, 0x81
.print:
	lodsb
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.print
	jmp	.done

.no_args:
	mov	si, msg_none
	call	pstr

.done:
	; Newline
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21

	mov	ax, 0x4C00
	int	0x21

pstr:
	lodsb
	or	al, al
	jz	.d
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	pstr
.d:	ret

msg	db	'Args:', 0
msg_none db	' (none)', 0
