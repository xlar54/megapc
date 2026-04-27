; TRC.COM — TSR INT 21h tracer (entry + exit registers)
;
; Each log slot is 16 bytes:
;   0..1: AX in
;   2..3: BX in
;   4..5: CX in
;   6..7: DX in
;   8..9: AX out
;  10..11: DX out
;  12..13: FLAGS out
;  14..15: padding

	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds

	mov	ax, 0x3521
	int	0x21
	mov	[old21_off], bx
	mov	[old21_seg], es

	mov	word [log_pos], 0
	mov	word [log_count], 0

	mov	dx, hook21
	mov	ax, 0x2521
	int	0x21

	mov	ah, 0x09
	mov	dx, msg
	int	0x21

	mov	ax, resident_end
	add	ax, 15
	mov	cl, 4
	shr	ax, cl
	add	ax, 0x10
	mov	dx, ax
	mov	ax, 0x3100
	int	0x21

; --- Hook ---
; Stack at entry: [ FLAGS-INT, CS-INT, IP-INT ]
; Caller's regs in AX/BX/CX/DX/SI/DI/ES/DS.
hook21:
	; Save everything we need to access caller regs
	push	bp
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	ds
	push	es

	push	cs
	pop	ds

	; Compute slot pointer: log_buf + log_pos*16
	mov	bx, [log_pos]
	mov	cl, 4
	shl	bx, cl
	add	bx, log_buf

	; Save it for exit logging
	mov	[current_slot], bx

	mov	bp, sp
	; Stack from BP (after all pushes):
	;   bp+0  = ES
	;   bp+2  = DS
	;   bp+4  = DI
	;   bp+6  = SI
	;   bp+8  = DX
	;   bp+10 = CX
	;   bp+12 = BX
	;   bp+14 = AX
	;   bp+16 = BP (caller's)
	;   bp+18 = IP from INT
	;   bp+20 = CS from INT
	;   bp+22 = FLAGS from INT

	mov	ax, [bp+14]
	mov	[bx+0], ax
	mov	ax, [bp+12]
	mov	[bx+2], ax
	mov	ax, [bp+10]
	mov	[bx+4], ax
	mov	ax, [bp+8]
	mov	[bx+6], ax
	; Signature bytes at slot+14, +15 to verify alignment in dump
	mov	byte [bx+14], 0xAB
	mov	byte [bx+15], 0xCD

	; Decide whether to tail-call (call doesn't return) or call-far
	; (so we can log return values). AH=00, 31, 4B, 4C are non-returning.
	mov	al, [bp+15]		; caller's AH (high byte of AX at bp+14)
	mov	byte [tail_call], 0
	cmp	al, 0x00
	je	.set_tail
	cmp	al, 0x31
	je	.set_tail
	cmp	al, 0x4B
	je	.set_tail
	cmp	al, 0x4C
	jne	.no_tail
.set_tail:
	mov	byte [tail_call], 1
.no_tail:
	; Pre-zero the exit slots so a non-returning call shows 0000 0000 0
	mov	word [bx+8], 0
	mov	word [bx+10], 0
	mov	word [bx+12], 0

	; Always advance log_pos here (tail-call path won't reach the
	; advance code below).
	mov	ax, [log_pos]
	inc	ax
	cmp	ax, LOG_SLOTS
	jb	.lp_ok2
	xor	ax, ax
.lp_ok2:
	mov	[log_pos], ax
	inc	word [log_count]

	; Restore caller's regs
	pop	es
	pop	ds
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	pop	bp

	cmp	byte [cs:tail_call], 0
	jne	.tail
	; Stack: [ FLAGS-INT, CS-INT, IP-INT ]
	; Normal chain via simulated INT (pushf + call far)
	pushf
	call	far [cs:old21_off]
	; After return: caller-visible regs are in AX/BX/CX/DX/etc; CF in flags

	; Save exit values
	push	bp
	push	ax
	push	bx
	push	dx
	push	ds
	pushf

	push	cs
	pop	ds

	mov	bx, [current_slot]

	mov	bp, sp
	; Stack from BP:
	;   bp+0  = FLAGS (from pushf above)
	;   bp+2  = saved DS
	;   bp+4  = saved DX
	;   bp+6  = saved BX
	;   bp+8  = saved AX
	;   bp+10 = saved BP

	mov	ax, [bp+8]
	mov	[bx+8], ax		; AX out
	mov	ax, [bp+4]
	mov	[bx+10], ax		; DX out
	mov	ax, [bp+0]
	mov	[bx+12], ax		; FLAGS out

	popf
	pop	ds
	pop	dx
	pop	bx
	pop	ax
	pop	bp

	; (log_pos already advanced before the call so tail-call path also counts.)

	; Copy current FLAGS into the FLAGS-INT slot on the stack so the
	; caller's IRET-popped FLAGS reflect what the original handler set.
	; INT pushes IP, CS, FLAGS (IP on top). After push bp / push ax:
	;   bp+0 = saved AX, bp+2 = saved BP, bp+4 = IP, bp+6 = CS, bp+8 = FLAGS
	push	bp
	push	ax
	mov	bp, sp
	pushf
	pop	ax
	mov	[bp+8], ax
	pop	ax
	pop	bp

	iret

.tail:
	; Tail-call: chain to original handler without expecting return.
	; Stack still has [FLAGS-INT, CS-INT, IP-INT] from caller's INT.
	jmp	far [cs:old21_off]

; --- Data ---
LOG_SLOTS	equ	256

msg		db	'Tracer installed (entry+exit logging)', 0x0D, 0x0A, '$'

old21_off	dw	0
old21_seg	dw	0

log_magic	db	0xDE, 0xAD, 0xBE, 0xEF
log_pos		dw	0
log_count	dw	0
current_slot	dw	0
tail_call	db	0
log_buf		times LOG_SLOTS * 16 db 0

resident_end:
