; SEEKTEST.COM — minimal seek test
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Create a test file with "ABCD"
	mov	ah, 0x3C
	mov	cx, 0
	mov	dx, fname
	int	0x21
	jc	.err
	mov	[hdl], ax

	; Write ABCD
	mov	ah, 0x40
	mov	bx, [hdl]
	mov	cx, 4
	mov	dx, data
	int	0x21

	; Close
	mov	ah, 0x3E
	mov	bx, [hdl]
	int	0x21

	; Open for read
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.err
	mov	[hdl], ax

	; Print handle number
	mov	si, msg1
	call	pstr
	mov	ax, [hdl]
	call	phex
	call	nl

	; Read 2 bytes
	mov	ah, 0x3F
	mov	bx, [hdl]
	mov	cx, 2
	mov	dx, buf
	int	0x21

	; Print bytes read
	mov	si, msg2
	call	pstr
	call	phex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, [buf]
	mov	ah, 0x02
	int	0x21
	mov	dl, [buf+1]
	mov	ah, 0x02
	int	0x21
	call	nl

	; Seek 0 from current to get position
	mov	bx, [hdl]
	mov	ax, 0x4201		; method 1, offset 0
	xor	cx, cx
	xor	dx, dx
	int	0x21

	; Print position
	mov	si, msg3
	call	pstr
	call	phex
	call	nl

	; Seek +1 from current
	mov	bx, [hdl]
	mov	ax, 0x4201
	xor	cx, cx
	mov	dx, 1
	int	0x21

	; Print position
	mov	si, msg4
	call	pstr
	call	phex
	call	nl

	; Read 1 byte
	mov	ah, 0x3F
	mov	bx, [hdl]
	mov	cx, 1
	mov	dx, buf
	int	0x21
	mov	si, msg5
	call	pstr
	mov	dl, [buf]
	mov	ah, 0x02
	int	0x21
	call	nl

	; Close and delete
	mov	ah, 0x3E
	mov	bx, [hdl]
	int	0x21
	mov	ah, 0x41
	mov	dx, fname
	int	0x21

	mov	ax, 0x4C00
	int	0x21

.err:
	mov	si, msg_err
	call	pstr
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

fname	db	'SEEK.TMP', 0
data	db	'ABCD'
msg1	db	'Handle: ', 0
msg2	db	'Read 2: ', 0
msg3	db	'Pos after read: ', 0
msg4	db	'Pos after +1: ', 0
msg5	db	'Byte at pos: ', 0
msg_err	db	'ERROR', 0x0D, 0x0A, 0
hdl	dw	0
buf	times 4 db 0
