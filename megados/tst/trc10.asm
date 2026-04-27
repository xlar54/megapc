; TRC10.COM — TSR INT 10h tracer (entry + exit registers)
;
; Each log slot is 16 bytes:
;   0..1:  AX in
;   2..3:  BX in
;   4..5:  CX in
;   6..7:  DX in
;   8..9:  AX out
;  10..11: BX out
;  12..13: FLAGS out
;  14..15: signature 0xAB 0xCD

	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds

	mov	ax, 0x3510		; Get INT 10h vector
	int	0x21
	mov	[old10_off], bx
	mov	[old10_seg], es

	mov	word [log_pos], 0
	mov	word [log_count], 0

	; Print banner BEFORE installing the hook so it doesn't eat the buffer
	mov	ah, 0x09
	mov	dx, msg
	int	0x21

	; Now install the hook
	mov	dx, hook10
	mov	ax, 0x2510		; Set INT 10h vector
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
hook10:
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

	; If buffer is full, skip logging entirely
	mov	ax, [log_pos]
	cmp	ax, LOG_SLOTS
	jae	.skip_log

	; Compute slot pointer: log_buf + log_pos*16
	mov	bx, ax
	mov	cl, 4
	shl	bx, cl
	add	bx, log_buf

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

	mov	ax, [bp+14]
	mov	[bx+0], ax		; AX in
	mov	ax, [bp+12]
	mov	[bx+2], ax		; BX in
	mov	ax, [bp+10]
	mov	[bx+4], ax		; CX in
	mov	ax, [bp+8]
	mov	[bx+6], ax		; DX in
	mov	byte [bx+14], 0xAB
	mov	byte [bx+15], 0xCD

	mov	word [bx+8], 0
	mov	word [bx+10], 0
	mov	word [bx+12], 0

	inc	word [log_pos]
	inc	word [log_count]
	mov	byte [log_active], 1
	jmp	.do_chain

.skip_log:
	mov	byte [log_active], 0

.do_chain:
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

	; Chain via simulated INT (pushf + call far)
	pushf
	call	far [cs:old10_off]

	; If we didn't log entry, skip exit logging too
	cmp	byte [cs:log_active], 0
	je	.no_exit_log

	; Save exit values
	push	bp
	push	ax
	push	bx
	push	ds
	pushf

	push	cs
	pop	ds

	mov	bx, [current_slot]

	mov	bp, sp
	; Stack from BP:
	;   bp+0  = FLAGS
	;   bp+2  = saved DS
	;   bp+4  = saved BX
	;   bp+6  = saved AX
	;   bp+8  = saved BP

	mov	ax, [bp+6]
	mov	[bx+8], ax		; AX out
	mov	ax, [bp+4]
	mov	[bx+10], ax		; BX out
	mov	ax, [bp+0]
	mov	[bx+12], ax		; FLAGS out

	popf
	pop	ds
	pop	bx
	pop	ax
	pop	bp

.no_exit_log:

	; Copy current FLAGS into the saved FLAGS-INT slot so caller's
	; IRET-popped FLAGS reflect what the original handler set.
	push	bp
	push	ax
	mov	bp, sp
	pushf
	pop	ax
	mov	[bp+8], ax
	pop	ax
	pop	bp

	iret

; --- Data ---
LOG_SLOTS	equ	1024

msg		db	'TRC10 installed (INT 10h entry+exit logging)', 0x0D, 0x0A, '$'

old10_off	dw	0
old10_seg	dw	0

log_magic	db	0xDE, 0xAD, 0xC0, 0xDE
log_pos		dw	0
log_count	dw	0
current_slot	dw	0
log_active	db	0
log_buf		times LOG_SLOTS * 16 db 0

resident_end:
