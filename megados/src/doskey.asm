; DOSKEY.COM — Command history TSR for MegaDOS
; Hooks INT 21h AH=0Ah (buffered input) to add command recall
; Up/Down arrows browse history, Escape clears line
	cpu	8086
	org	0x0100

MAX_HISTORY	equ	16
MAX_LINE	equ	127
HIST_ENTRY	equ	MAX_LINE + 1		; 128 bytes per entry

start:
	; Print banner
	mov	ah, 0x09
	mov	dx, msg_banner
	int	0x21

	; Check if already installed (look for signature in IVT hook)
	mov	ax, 0
	mov	es, ax
	mov	bx, [es:0x84]		; INT 21h offset
	mov	es, [es:0x86]		; INT 21h segment
	cmp	word [es:bx-2], 0x4B44	; 'DK' signature
	je	.already

	; Save old INT 21h vector
	xor	ax, ax
	mov	es, ax
	mov	ax, [es:0x84]
	mov	[old_int21], ax
	mov	ax, [es:0x86]
	mov	[old_int21+2], ax

	; Install new INT 21h vector
	cli
	mov	word [es:0x84], new_int21
	mov	[es:0x86], cs
	sti

	; Initialize history
	mov	word [hist_count], 0
	mov	word [hist_pos], 0

	; Calculate paragraphs to keep resident
	; Everything from PSP to end of resident data
	mov	ax, resident_end
	add	ax, 15			; Round up
	shr	ax, 1
	shr	ax, 1
	shr	ax, 1
	shr	ax, 1			; Convert to paragraphs
	mov	dx, ax

	; Go resident
	mov	ax, 0x3100
	int	0x21

.already:
	mov	ah, 0x09
	mov	dx, msg_already
	int	0x21
	mov	ax, 0x4C01
	int	0x21

; ============================================================================
; Resident code — INT 21h hook
; ============================================================================
	dw	0x4B44			; 'DK' signature (before entry point)
new_int21:
	cmp	ah, 0x0A
	je	.hook_0a
	; Pass through to original handler
	jmp	far [cs:old_int21]

.hook_0a:
	; Buffered input with history support
	; DS:DX = buffer (byte 0 = max len, byte 1 = actual len, byte 2+ = data)
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	es
	push	ds

	; Save buffer pointer
	mov	[cs:buf_seg], ds
	mov	[cs:buf_off], dx

	; Set up our DS
	push	cs
	pop	ds

	; Get max length from caller's buffer
	mov	es, [buf_seg]
	mov	di, [buf_off]
	mov	al, [es:di]		; Max length
	mov	[max_len], al

	; Reset history browse position
	mov	ax, [hist_count]
	mov	[browse_pos], ax	; Start past newest = "new line"

	; Clear the input
	xor	cx, cx			; CX = current length
	mov	di, [buf_off]
	add	di, 2			; DI = start of data area in caller's buffer

.input_loop:
	; Wait for key
	mov	ah, 0x00
	int	0x16

	; Check for extended key (AL=0)
	or	al, al
	jz	.extended_key

	; Enter
	cmp	al, 0x0D
	je	.enter

	; Escape
	cmp	al, 0x1B
	je	.escape

	; Backspace
	cmp	al, 0x08
	je	.backspace

	; Regular character — add to buffer
	cmp	cl, [max_len]
	jae	.beep
	mov	[es:di], al
	inc	di
	inc	cx
	; Echo
	mov	dl, al
	mov	ah, 0x02
	push	cx
	int	0x21
	pop	cx
	jmp	.input_loop

.extended_key:
	cmp	ah, 0x48		; Up arrow
	je	.history_up
	cmp	ah, 0x50		; Down arrow
	je	.history_down
	jmp	.input_loop		; Ignore other extended keys

.history_up:
	cmp	word [hist_count], 0
	je	.input_loop		; No history
	cmp	word [browse_pos], 0
	je	.input_loop		; Already at oldest
	dec	word [browse_pos]
	jmp	.recall

.history_down:
	mov	ax, [browse_pos]
	cmp	ax, [hist_count]
	jae	.input_loop		; Already past newest
	inc	word [browse_pos]
	mov	ax, [browse_pos]
	cmp	ax, [hist_count]
	je	.clear_line		; Past newest = empty line
	jmp	.recall

.recall:
	; Erase current line from screen
	call	.erase_line
	; Get history entry at browse_pos
	mov	ax, [browse_pos]
	call	.get_hist_ptr		; SI = history entry
	; Copy to caller's buffer and display
	mov	di, [buf_off]
	mov	es, [buf_seg]
	add	di, 2
	xor	cx, cx
.recall_copy:
	mov	al, [si]
	or	al, al
	jz	.recall_done
	cmp	cl, [max_len]
	jae	.recall_done
	mov	[es:di], al
	inc	di
	inc	cx
	; Echo character
	mov	dl, al
	mov	ah, 0x02
	push	cx
	push	si
	int	0x21
	pop	si
	pop	cx
	inc	si
	jmp	.recall_copy
.recall_done:
	jmp	.input_loop

.clear_line:
	call	.erase_line
	mov	di, [buf_off]
	mov	es, [buf_seg]
	add	di, 2
	xor	cx, cx
	jmp	.input_loop

.escape:
	call	.erase_line
	mov	di, [buf_off]
	mov	es, [buf_seg]
	add	di, 2
	xor	cx, cx
	; Reset browse position
	mov	ax, [hist_count]
	mov	[browse_pos], ax
	jmp	.input_loop

.backspace:
	or	cx, cx
	jz	.input_loop
	dec	di
	dec	cx
	; Erase on screen
	mov	dl, 0x08
	mov	ah, 0x02
	push	cx
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x08
	mov	ah, 0x02
	int	0x21
	pop	cx
	jmp	.input_loop

.beep:
	; Buffer full — beep
	mov	al, 0xB6
	out	0x43, al
	mov	al, 0xA9
	out	0x42, al
	mov	al, 0x04
	out	0x42, al
	in	al, 0x61
	or	al, 0x03
	out	0x61, al
	push	cx
	mov	cx, 0x2000
.beep_delay:
	dec	cx
	jnz	.beep_delay
	pop	cx
	in	al, 0x61
	and	al, 0xFC
	out	0x61, al
	jmp	.input_loop

.enter:
	; Null-terminate in buffer for history save
	mov	byte [es:di], 0x0D
	; Store actual length
	mov	di, [buf_off]
	mov	es, [buf_seg]
	mov	[es:di+1], cl

	; Save to history if non-empty
	or	cx, cx
	jz	.enter_done

	; Copy from caller's buffer to history
	push	cx
	push	di
	; Shift history down if full
	cmp	word [hist_count], MAX_HISTORY
	jb	.hist_not_full
	; Shift entries 1..MAX_HISTORY-1 down to 0..MAX_HISTORY-2
	push	ds
	push	es
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	si, hist_buffer + HIST_ENTRY
	mov	di, hist_buffer
	mov	cx, (MAX_HISTORY - 1) * HIST_ENTRY
	rep	movsb
	pop	es
	pop	ds
	dec	word [hist_count]
.hist_not_full:
	; Get pointer to next free slot
	mov	ax, [hist_count]
	call	.get_hist_ptr		; SI = slot
	mov	di, si			; DI = dest in history
	; Copy from caller's buffer
	pop	si			; SI = buf_off
	pop	cx
	push	cx
	push	si
	mov	es, [buf_seg]
	add	si, 2			; Skip max_len and actual_len bytes
	push	ds
	push	cs
	pop	ds			; DS = CS for history buffer
	push	es
	mov	es, [cs:buf_seg]
	; SI = caller buffer+2 (ES:SI), DI = history slot (DS:DI... no)
	; We need: source = caller buf+2 (buf_seg:buf_off+2)
	;          dest = history slot (CS:slot)
	pop	es			; ES = buf_seg
	xchg	si, di			; SI = history slot (in CS), DI = buf_off
	add	di, 2
	; Now copy from ES:DI (caller) to DS:SI (history)...
	; Actually let's just do it byte by byte
	pop	ds			; Restore original DS
	push	cs
	pop	ds			; DS = CS
	mov	si, di			; SI = buf_off + 2
	push	ds
	mov	ds, [cs:buf_seg]	; DS = caller segment
	; SI = buf_off + 2 in caller's segment
	; Need dest in CS segment
	pop	es			; ES was... this is getting messy

	; Simpler approach: just copy byte by byte
	push	cs
	pop	es			; ES = CS (dest = history)
	mov	ds, [cs:buf_seg]	; DS = caller's segment
	pop	si			; SI = buf_off
	pop	cx			; CX = length
	add	si, 2			; Past max_len and actual_len
	; DI = history slot (already set from .get_hist_ptr via SI, need to recalculate)
	push	cx
	mov	ax, [cs:hist_count]
	; get_hist_ptr: AX * HIST_ENTRY + hist_buffer
	push	dx
	mov	dx, HIST_ENTRY
	mul	dx
	add	ax, hist_buffer
	mov	di, ax
	pop	dx
	pop	cx
.save_copy:
	lodsb				; DS:SI = caller's buffer char
	mov	[es:di], al		; ES:DI = history slot
	inc	di
	dec	cx
	jnz	.save_copy
	mov	byte [es:di], 0		; Null terminate

	push	cs
	pop	ds			; Restore DS = CS
	inc	word [hist_count]
	; Reset browse position
	mov	ax, [hist_count]
	mov	[browse_pos], ax

.enter_done:
	; Print CR/LF
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21

	; Return to caller (don't chain to original INT 21h)
	pop	ds
	pop	es
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	iret

; --- Helper: erase current line on screen ---
; CX = number of characters to erase
.erase_line:
	push	cx
	push	dx
	jcxz	.erase_done
.erase_bs:
	; Backspace + space + backspace for each character
	mov	dl, 0x08
	mov	ah, 0x02
	push	cx
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x08
	mov	ah, 0x02
	int	0x21
	pop	cx
	dec	cx
	jnz	.erase_bs
.erase_done:
	pop	dx
	pop	cx
	ret

; --- Helper: get history pointer ---
; Input: AX = index (0 = oldest)
; Output: SI = pointer to history entry
.get_hist_ptr:
	push	dx
	mov	dx, HIST_ENTRY
	mul	dx
	add	ax, hist_buffer
	mov	si, ax
	pop	dx
	ret

; ============================================================================
; Resident data
; ============================================================================
old_int21:	dd	0
buf_seg:	dw	0
buf_off:	dw	0
max_len:	db	0
hist_count:	dw	0
hist_pos:	dw	0
browse_pos:	dw	0

; History buffer: MAX_HISTORY entries of HIST_ENTRY bytes each
hist_buffer:	times MAX_HISTORY * HIST_ENTRY db 0

resident_end:

; ============================================================================
; Non-resident data (discarded after going resident)
; ============================================================================
msg_banner	db	'DOSKEY installed.', 0x0D, 0x0A, '$'
msg_already	db	'DOSKEY already installed.', 0x0D, 0x0A, '$'
