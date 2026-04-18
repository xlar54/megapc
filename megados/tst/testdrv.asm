; TESTDRV.SYS — minimal test device driver
; Just prints a message at INIT and returns success for all commands
	cpu	8086
	org	0x0000		; .SYS files load at offset 0

; Device header
	dd	-1			; Next driver (filled by DOS)
	dw	0x8000			; Character device
	dw	strategy		; Strategy routine
	dw	interrupt		; Interrupt routine
	db	'TESTDRV '		; Device name

; ============================================================================
; Strategy — save request packet pointer
; ============================================================================
strategy:
	mov	[cs:req_ptr], bx
	mov	[cs:req_seg], es
	retf

; ============================================================================
; Interrupt — process request
; ============================================================================
interrupt:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	es

	mov	es, [cs:req_seg]
	mov	bx, [cs:req_ptr]
	mov	al, [es:bx+2]		; Command code

	cmp	al, 0			; INIT
	je	.init

	; All other commands — return success
	mov	word [es:bx+3], 0x0100
	jmp	.done

.init:
	; Print init message via BIOS (DOS not fully up yet)
	mov	si, msg_init
.print:
	mov	al, [cs:si]
	or	al, al
	jz	.print_done
	mov	ah, 0x0E
	push	bx
	mov	bx, 0x0007
	int	0x10
	pop	bx
	inc	si
	jmp	.print
.print_done:
	; Set break address (end of resident code)
	; Request packet offset 14 = break address offset
	; Request packet offset 16 = break address segment
	mov	word [es:bx+14], resident_end
	mov	ax, cs
	mov	[es:bx+16], ax
	mov	word [es:bx+3], 0x0100	; Done, no error
	jmp	.done

.done:
	pop	es
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	retf

; ============================================================================
; Data
; ============================================================================
req_ptr:	dw	0
req_seg:	dw	0
msg_init:	db	'TESTDRV.SYS loaded!', 0x0D, 0x0A, 0

resident_end:
