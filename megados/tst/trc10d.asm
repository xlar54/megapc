; TRC10D.COM — print INT 10h log captured by TRC10.COM TSR

	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds

	; Get INT 10h vector — TRC10's hook seg
	mov	ax, 0x3510
	int	0x21
	mov	[trc_seg], es

	; Scan TRC10's seg for magic
	push	es
	pop	ds
	xor	si, si
.scan:
	cmp	byte [si], 0xDE
	jne	.scan_next
	cmp	byte [si+1], 0xAD
	jne	.scan_next
	cmp	byte [si+2], 0xC0
	jne	.scan_next
	cmp	byte [si+3], 0xDE
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
	; Save log info (DS = TRC10's seg)
	mov	ax, [si+4]
	mov	[cs:log_pos], ax
	mov	ax, [si+6]
	mov	[cs:log_count], ax
	mov	ax, si
	add	ax, 11			; magic(4) + log_pos(2) + log_count(2) + current_slot(2) + log_active(1)
	mov	[cs:log_buf_off], ax

	; Read old10_off / old10_seg (4 bytes before magic)
	mov	bx, si
	sub	bx, 4
	mov	dx, [bx+0]		; old10 offset
	mov	cx, [bx+2]		; old10 segment

	; Switch DS to ours
	push	cs
	pop	ds

	; Restore original INT 10h via DOS — last call that goes through hook
	push	ds
	mov	ds, cx
	mov	ax, 0x2510
	int	0x21
	pop	ds

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

	; Optional skip arg: parse decimal number from PSP cmdline at 0080h
	call	parse_skip_arg
	mov	[cs:start_idx], ax	; AX = skip count (0 if no arg)

	mov	ax, [log_count]
	cmp	ax, [cs:start_idx]
	jbe	.no_entries
	sub	ax, [cs:start_idx]
	mov	cx, ax
	mov	bx, [cs:start_idx]
	jmp	.has_entries
.no_entries:
	jmp	.done
.has_entries:

.print_loop:
	push	cx
	push	bx

	; Slot offset = bx*16 + log_buf_off
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

	; BX out
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
	cmp	bx, 1024
	jb	.bx_ok
	xor	bx, bx
.bx_ok:
	pop	cx
	; Pause every 22 lines
	inc	word [cs:line_ctr]
	cmp	word [cs:line_ctr], 22
	jb	.no_pause
	mov	word [cs:line_ctr], 0
	push	cx
	mov	ah, 0x09
	mov	dx, msg_more
	int	0x21
	mov	ah, 0x07		; Read char no echo
	int	0x21
	; CRLF
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	pop	cx
.no_pause:
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

; Parse decimal skip count from PSP command-line tail at 0080h.
; Format: byte 80h = length, 81h+ = chars (with leading space).
; Returns AX = parsed value (0 if no/invalid arg).
parse_skip_arg:
	push	bx
	push	cx
	push	si
	xor	ax, ax
	mov	si, 0x0081		; PSP cmdline starts at 81h (after length byte)
	mov	cl, [0x0080]
	xor	ch, ch
.skip_ws:
	jcxz	.psa_done
	cmp	byte [si], ' '
	jne	.read_digits
	inc	si
	dec	cx
	jmp	.skip_ws
.read_digits:
	xor	bx, bx
.rd_loop:
	jcxz	.psa_set
	mov	al, [si]
	cmp	al, '0'
	jb	.psa_set
	cmp	al, '9'
	ja	.psa_set
	sub	al, '0'
	xor	ah, ah
	push	dx
	mov	dx, bx
	shl	bx, 1
	shl	bx, 1
	add	bx, dx			; bx = old*5
	pop	dx
	shl	bx, 1			; bx = old*10
	add	bx, ax
	inc	si
	dec	cx
	jmp	.rd_loop
.psa_set:
	mov	ax, bx
.psa_done:
	pop	si
	pop	cx
	pop	bx
	ret

msg_no		db	'TRC10 magic not found', 0x0D, 0x0A, '$'
msg_total	db	'Total INT 10h calls: $'
msg_hdr		db	'AH AL  BX   CX   DX   => AX_o BX_o CF', 0x0D, 0x0A, '$'
msg_more	db	'-- More (any key) --$'

trc_seg		dw	0
log_pos		dw	0
log_count	dw	0
log_buf_off	dw	0
start_idx	dw	0
line_ctr	dw	0
