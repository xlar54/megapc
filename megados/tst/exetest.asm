; EXETEST.COM — minimal test: read GWBASIC.EXE across cluster boundary
; No seek — just sequential reads
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Open GWBASIC.EXE
	mov	ax, 0x3D00
	mov	dx, fname
	int	0x21
	jc	.open_err
	mov	[handle], ax

	; Test 1: Read first 4 bytes (should be 4D 5A D0 00 = MZ header)
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	jc	.read_err
	mov	si, msg_t1
	call	print_str
	mov	si, buf
	call	print_4bytes
	call	newline

	; Test 2: Read next 1020 bytes (to finish first cluster of 1024)
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1020
	mov	dx, bigbuf
	int	0x21
	jc	.read_err
	push	ax
	mov	si, msg_t2
	call	print_str
	pop	ax
	call	print_hex	; Should show 03FC = 1020
	call	newline

	; Test 3: Read 4 bytes (these are from the SECOND cluster)
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	jc	.read_err
	mov	si, msg_t3
	call	print_str
	push	ax
	call	print_hex	; Should show 0004
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax
	mov	si, buf
	call	print_4bytes	; Should show 00 00 A0 67
	call	newline

	; Test 4: Read 1024 more (third cluster start)
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1024
	mov	dx, bigbuf
	int	0x21
	jc	.read_err

	; Test 5: Read 4 from third cluster boundary
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	jc	.read_err
	mov	si, msg_t5
	call	print_str
	push	ax
	call	print_hex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax
	mov	si, buf
	call	print_4bytes	; Should show 06 28 08 01
	call	newline

	; Close
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	; Now test seek: reopen and seek
	mov	ax, 0x3D00
	mov	dx, fname
	int	0x21
	jc	.open_err
	mov	[handle], ax

	; Seek to 1024
	mov	ah, 0x42
	mov	al, 0
	mov	bx, [handle]
	xor	cx, cx
	mov	dx, 1024
	int	0x21
	jc	.seek_err

	; Read 4 bytes
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	jc	.read_err
	mov	si, msg_t6
	call	print_str
	push	ax
	call	print_hex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax
	mov	si, buf
	call	print_4bytes
	call	newline

	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	mov	ax, 0x4C00
	int	0x21

.open_err:
	mov	si, msg_operr
	call	print_str
	mov	ax, 0x4C01
	int	0x21
.read_err:
	mov	si, msg_rderr
	call	print_str
	mov	ax, 0x4C01
	int	0x21
.seek_err:
	mov	si, msg_skerr
	call	print_str
	mov	ax, 0x4C01
	int	0x21

; --- helpers ---
print_str:
	push	ax
.ps:	lodsb
	or	al, al
	jz	.pd
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.ps
.pd:	pop	ax
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

print_hex:
	push	cx
	push	dx
	mov	cx, 4
.ph:	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.po
	add	al, 7
.po:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph
	pop	dx
	pop	cx
	ret

print_4bytes:
	push	cx
	mov	cx, 4
.p4:	lodsb
	push	cx
	push	ax
	shr	al, 1
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.h1
	add	al, 7
.h1:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.h2
	add	al, 7
.h2:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax
	pop	cx
	dec	cx
	jnz	.p4
	pop	cx
	ret

; --- data ---
fname	db	'GWBASIC.EXE', 0
msg_t1	db	'Byte 0-3: ', 0
msg_t2	db	'Read 1020: ', 0
msg_t3	db	'@1024: ', 0
msg_t5	db	'@2048: ', 0
msg_t6	db	'Seek1024: ', 0
msg_operr db	'Open error', 0x0D, 0x0A, 0
msg_rderr db	'Read error', 0x0D, 0x0A, 0
msg_skerr db	'Seek error', 0x0D, 0x0A, 0

handle	dw	0
buf	times 16 db 0
bigbuf	times 1024 db 0
