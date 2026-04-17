; CHK050F.COM — check the byte at 0000:050F
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Read 0000:050F
	xor	ax, ax
	mov	es, ax
	mov	al, [es:0x050F]

	; Print it
	push	ax
	mov	si, msg
	call	pstr
	pop	ax
	xor	ah, ah
	call	phex
	call	nl

	; Also clear it
	mov	byte [es:0x050F], 0
	mov	si, msg2
	call	pstr
	call	nl

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

phex:
	push	cx
	push	dx
	mov	cx, 4
.l:	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.o
	add	al, 7
.o:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.l
	pop	dx
	pop	cx
	ret

nl:
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	ret

msg	db	'0000:050F = ', 0
msg2	db	'Cleared to 0', 0
