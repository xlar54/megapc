; MEM.COM — Display memory usage
; Usage: MEM
	cpu	8086
	org	0x0100

PARA_SIZE	equ	16		; Bytes per paragraph

start:
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	call	crlf

	; Shrink our own memory block so free memory is visible
	mov	ah, 0x4A
	mov	bx, (end_of_prog - start + 0x100 + 15) / 16  ; Paragraphs needed
	push	cs
	pop	es
	int	0x21

	; Total conventional memory = 640KB
	mov	si, msg_total
	call	pstr

	; Get total free memory by probing with AH=48h BX=FFFF
	mov	ah, 0x48
	mov	bx, 0xFFFF
	int	0x21			; Always fails, BX = largest free block in paragraphs
	mov	[largest_free], bx

	; Walk MCB chain to count used and free
	mov	word [used_lo], 0
	mov	word [used_hi], 0
	mov	word [free_lo], 0
	mov	word [free_hi], 0
	mov	word [block_count], 0

	; Get first MCB — it's at PROG_SEG (0x2000)
	; DOS stores MCBs starting at the first allocatable segment
	mov	ax, 0x2000		; PROG_SEG
.walk_mcb:
	mov	es, ax
	; MCB format: byte type, word owner, word size (in paragraphs)
	mov	bl, [es:0x00]		; Type: 'M' or 'Z'
	mov	cx, [es:0x01]		; Owner (0 = free)
	mov	dx, [es:0x03]		; Size in paragraphs

	inc	word [block_count]

	; Convert paragraphs to bytes (DX * 16)
	; DX is paragraphs, multiply by 16
	push	ax
	mov	ax, dx
	mov	bx, PARA_SIZE
	mul	bx			; DX:AX = bytes
	cmp	word [es:0x01], 0	; Owner = 0 = free
	je	.is_free
	; Used block
	add	[used_lo], ax
	adc	[used_hi], dx
	jmp	.next_mcb
.is_free:
	add	[free_lo], ax
	adc	[free_hi], dx
.next_mcb:
	pop	ax
	; Check if last MCB
	cmp	byte [es:0x00], 'Z'
	je	.walk_done
	; Next MCB = current + 1 + size
	add	ax, [es:0x03]
	inc	ax
	jmp	.walk_mcb

.walk_done:
	; Print used memory
	mov	si, msg_used
	call	pstr
	mov	ax, [used_lo]
	mov	dx, [used_hi]
	call	pdec32
	mov	si, msg_used_suf
	call	pstr

	; Print free memory
	mov	si, msg_free
	call	pstr
	mov	ax, [free_lo]
	mov	dx, [free_hi]
	call	pdec32
	mov	si, msg_free_suf
	call	pstr

	; Print largest executable program size
	mov	si, msg_largest
	call	pstr
	mov	ax, [largest_free]
	mov	bx, PARA_SIZE
	mul	bx			; DX:AX = bytes
	call	pdec32
	mov	si, msg_lrg_suf
	call	pstr

	call	crlf
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; Helpers
; ============================================================================
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

; pdec32 — Print DX:AX as unsigned 32-bit decimal
pdec32:
	push	cx
	push	bx
	push	si
	push	di
	xor	cx, cx
	mov	si, dx
.d32_loop:
	push	ax
	mov	ax, si
	xor	dx, dx
	mov	bx, 10
	div	bx
	mov	si, ax
	pop	ax
	push	dx
	pop	bx
	push	bx
	mov	dx, bx
	mov	bx, 10
	div	bx
	pop	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.d32_loop
	or	si, si
	jnz	.d32_loop
.d32_print:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.d32_print
	pop	di
	pop	si
	pop	bx
	pop	cx
	ret

; ============================================================================
; Messages
; ============================================================================
msg_total	db	'  655360 bytes total conventional memory', 0x0D, 0x0A, 0
msg_used	db	'  ', 0
msg_used_suf	db	' bytes used', 0x0D, 0x0A, 0
msg_free	db	'  ', 0
msg_free_suf	db	' bytes free', 0x0D, 0x0A, 0
msg_largest	db	'  ', 0
msg_lrg_suf	db	' bytes largest executable program size', 0x0D, 0x0A, 0

; ============================================================================
; Data
; ============================================================================
largest_free	dw	0
used_lo		dw	0
used_hi		dw	0
free_lo		dw	0
free_hi		dw	0
block_count	dw	0

end_of_prog:
