; A1TEST.COM — reads A1.BAS in 128-byte chunks, marks each chunk
; Usage: A1TEST
;
; Output format:
;   [128] <128 bytes>
;   [128] <128 bytes>
;   [N]   <N bytes>
;   [EOF]
;
; If the second [128] never appears or shows fewer bytes than expected,
; AH=3F has a sequential-read bug.
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	error
	mov	[handle], ax

	xor	si, si			; chunk counter

read_loop:
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buffer
	int	0x21
	jc	error
	cmp	ax, 0
	je	eof
	mov	[bytes_read], ax

	; Print "[NNN] " marker (chunk count and bytes-read decimal)
	push	si
	push	ax
	mov	ah, 0x02
	mov	dl, '['
	int	0x21
	pop	ax
	push	ax
	call	print_decimal	; prints AX as decimal
	pop	ax
	pop	si
	push	ax
	mov	ah, 0x02
	mov	dl, ']'
	int	0x21
	mov	dl, ' '
	int	0x21
	pop	ax

	; Print AX bytes from buffer to stdout
	mov	cx, [bytes_read]
	mov	bx, 1
	mov	dx, buffer
	mov	ah, 0x40
	int	0x21

	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	int	0x21

	inc	si
	cmp	si, 10			; safety: cap at 10 chunks
	jb	read_loop

eof:
	mov	ah, 0x09
	mov	dx, eofmsg
	int	0x21

	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	mov	ah, 0x4C
	mov	al, 0
	int	0x21

error:
	mov	ah, 0x09
	mov	dx, errmsg
	int	0x21
	mov	ah, 0x4C
	mov	al, 1
	int	0x21

; print AX as unsigned decimal via INT 21h AH=02
print_decimal:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	bx, 10
	xor	cx, cx			; digit counter
.pd_div:
	xor	dx, dx
	div	bx			; AX/10 -> AX, DX = remainder
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_div
.pd_emit:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	loop	.pd_emit
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

fname		db	'A1.BAS', 0
errmsg		db	'Error opening A1.BAS', 0x0D, 0x0A, '$'
eofmsg		db	'[EOF]', 0x0D, 0x0A, '$'
handle		dw	0
bytes_read	dw	0
buffer		times 128 db 0
