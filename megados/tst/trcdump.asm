; TRCDUMP.COM — print INT 21h log captured by TRC.COM TSR

	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds

	; Get INT 21h vector
	mov	ax, 0x3521
	int	0x21
	mov	[trc_seg], es

	; Scan TRC's seg for magic
	push	es
	pop	ds
	xor	si, si
.scan:
	cmp	byte [si], 0xDE
	jne	.scan_next
	cmp	byte [si+1], 0xAD
	jne	.scan_next
	cmp	byte [si+2], 0xBE
	jne	.scan_next
	cmp	byte [si+3], 0xEF
	je	.found
.scan_next:
	inc	si
	cmp	si, 0xFFF0
	jb	.scan
	push	cs
	pop	ds
	mov	ah, 0x09
	mov	dx, msg_no
	int	0x21
	mov	ax, 0x4C01
	int	0x21

.found:
	; Save log info (DS = TRC's seg)
	mov	ax, [si+4]
	mov	[cs:log_pos], ax
	mov	ax, [si+6]
	mov	[cs:log_count], ax
	mov	ax, si
	add	ax, 11			; magic(4) + log_pos(2) + log_count(2) + current_slot(2) + tail_call(1)
	mov	[cs:log_buf_off], ax

	; Read old21_off / old21_seg (4 bytes before magic in TRC's data layout)
	mov	bx, si
	sub	bx, 4
	mov	dx, [bx+0]		; old21 offset
	mov	cx, [bx+2]		; old21 segment

	; Switch DS to ours
	push	cs
	pop	ds

	; Restore original INT 21h via DOS — last call that goes through hook
	push	ds
	mov	ds, cx
	mov	ax, 0x2521
	int	0x21
	pop	ds
	; From here on INT 21h goes to original DOS handler — no logging.

	; Print "Total: NN calls"
	mov	ah, 0x09
	mov	dx, msg_total
	int	0x21
	mov	ax, [log_count]
	call	print_dec
	call	newline

	mov	ah, 0x09
	mov	dx, msg_hdr
	int	0x21

	; Determine how many entries to print
	mov	ax, [log_count]
	cmp	ax, 256
	jbe	.cap_ok
	mov	ax, 256
.cap_ok:
	mov	cx, ax
	or	cx, cx
	jnz	.has_entries
	jmp	.done
.has_entries:
	; (no cap — print all entries)

	; Starting index: if count >= 256, start at log_pos (oldest in circle)
	; else start at 0
	mov	ax, [log_count]
	cmp	ax, 256
	jb	.start_zero
	mov	bx, [log_pos]
	jmp	.loop_init
.start_zero:
	xor	bx, bx
.loop_init:

.print_loop:
	push	cx
	push	bx

	; Compute slot offset = bx*16 + log_buf_off
	mov	ax, bx
	mov	cl, 4
	shl	ax, cl
	add	ax, [cs:log_buf_off]
	mov	si, ax

	; AH (caller's high byte of AX, at slot offset 1)
	mov	es, [cs:trc_seg]
	mov	al, [es:si+1]
	call	print_hex2
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; AL
	mov	es, [cs:trc_seg]
	mov	al, [es:si+0]
	call	print_hex2
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; BX
	mov	es, [cs:trc_seg]
	mov	ax, [es:si+2]
	call	print_hex4
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; CX
	mov	es, [cs:trc_seg]
	mov	ax, [es:si+4]
	call	print_hex4
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; DX
	mov	es, [cs:trc_seg]
	mov	ax, [es:si+6]
	call	print_hex4

	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	mov	dl, '>'
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; AX out
	mov	es, [cs:trc_seg]
	mov	ax, [es:si+8]
	call	print_hex4
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; DX out (return DX, e.g., for AH=44 IOCTL info word)
	mov	es, [cs:trc_seg]
	mov	ax, [es:si+10]
	call	print_hex4
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21

	; CF (low bit of FLAGS at slot+12)
	mov	es, [cs:trc_seg]
	mov	al, [es:si+12]
	and	al, 0x01
	add	al, '0'
	mov	dl, al
	mov	ah, 0x02
	int	0x21

	call	newline

	pop	bx
	inc	bx
	cmp	bx, 256
	jb	.bx_ok
	xor	bx, bx
.bx_ok:
	pop	cx
	dec	cx
	jz	.done
	jmp	.print_loop

.done:
	mov	ax, 0x4C00
	int	0x21

print_hex_nibble:
	cmp	al, 10
	jb	.lo
	add	al, 'A' - 10 - '0'
.lo:
	add	al, '0'
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	ret

print_hex2:
	push	ax
	push	ax
	shr	al, 1
	shr	al, 1
	shr	al, 1
	shr	al, 1
	and	al, 0x0F
	call	print_hex_nibble
	pop	ax
	and	al, 0x0F
	call	print_hex_nibble
	pop	ax
	ret

print_hex4:
	push	ax
	mov	al, ah
	call	print_hex2
	pop	ax
	call	print_hex2
	ret

print_dec:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	bx, 10
	xor	cx, cx
.div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.div
.emit:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	loop	.emit
	pop	dx
	pop	cx
	pop	bx
	pop	ax
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

msg_no		db	'Magic not found', 0x0D, 0x0A, '$'
msg_total	db	'Total INT 21h calls: $'
msg_hdr		db	'AH AL  BX   CX   DX   => AX_o DX_o CF', 0x0D, 0x0A, '$'

trc_seg		dw	0
log_pos		dw	0
log_count	dw	0
log_buf_off	dw	0
