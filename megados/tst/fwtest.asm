; FWTEST.COM — test AH=3Ch create file and report error
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Try to create OUTPUT.TXT
	mov	ah, 0x3C
	mov	cx, 0
	mov	dx, fname
	int	0x21
	jc	.err

	; Success
	push	ax		; save handle
	mov	si, msg_ok
	call	pstr
	pop	ax
	call	phex
	call	nl

	; Close it
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Try writing
	mov	si, msg_done
	call	pstr
	mov	ax, 0x4C00
	int	0x21

.err:
	push	ax
	mov	si, msg_err
	call	pstr
	pop	ax
	call	phex
	call	nl
	mov	ax, 0x4C01
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
.h:	rol	ax, 1
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
	jnz	.h
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

fname	db	'OUTPUT.TXT', 0
msg_ok	db	'Created OK, handle=', 0
msg_err	db	'Create FAILED, AX=', 0
msg_done db	'File created and closed successfully', 0x0D, 0x0A, 0
