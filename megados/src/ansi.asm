; ANSI.SYS - MegaDOS ANSI console driver
; Load with DEVICE=ANSI.SYS in CONFIG.SYS.
;
; This is a character-device CON replacement. It accepts normal console
; read/status requests and parses common ANSI escape sequences on writes.

	cpu	8086
	org	0x0000

; Device header
	dd	-1			; Next driver, filled by DOS
	dw	0x8013			; Char + stdin + stdout + special
	dw	strategy
	dw	interrupt
	db	'ANSI    '

ESC		equ	0x1B
ROWS		equ	25
COLS		equ	80
REQ_DONE	equ	0x0100
REQ_BUSY	equ	0x0200

; ============================================================================
; Strategy - save request packet pointer
; ============================================================================
strategy:
	mov	[cs:req_ptr], bx
	mov	[cs:req_seg], es
	retf

; ============================================================================
; Interrupt - process request
; ============================================================================
interrupt:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	ds
	push	es

	mov	es, [cs:req_seg]
	mov	bx, [cs:req_ptr]
	mov	al, [es:bx+2]

	cmp	al, 0			; INIT
	je	.init
	cmp	al, 4			; READ
	je	.read
	cmp	al, 5			; NONDESTRUCTIVE READ
	je	.nd_read
	cmp	al, 6			; INPUT STATUS
	je	.in_status
	cmp	al, 7			; INPUT FLUSH
	je	.in_flush
	cmp	al, 8			; WRITE
	je	.write
	cmp	al, 10			; OUTPUT STATUS
	je	.out_status

	mov	word [es:bx+3], REQ_DONE
	jmp	.done

.init:
	mov	byte [cs:ansi_state], 0
	mov	byte [cs:ansi_attr], 0x07
	mov	byte [cs:saved_row], 0
	mov	byte [cs:saved_col], 0
	mov	byte [cs:pending_scan], 0
	mov	byte [cs:dsr_head], 0
	mov	byte [cs:dsr_len], 0
	call	ansi_init_banner
	mov	word [es:bx+14], resident_end
	mov	ax, cs
	mov	[es:bx+16], ax
	mov	word [es:bx+3], REQ_DONE
	jmp	.done

.read:
	cld
	mov	cx, [es:bx+18]
	mov	di, [es:bx+14]
	mov	ax, [es:bx+16]
	push	es
	mov	es, ax
	xor	dx, dx
.read_loop:
	jcxz	.read_done
	; Highest priority: queued DSR response bytes.
	cmp	byte [cs:dsr_len], 0
	je	.read_no_dsr
	push	bx
	xor	bh, bh
	mov	bl, [cs:dsr_head]
	mov	al, [cs:dsr_buf+bx]
	pop	bx
	inc	byte [cs:dsr_head]
	mov	ah, [cs:dsr_head]
	cmp	ah, [cs:dsr_len]
	jb	.read_store
	mov	byte [cs:dsr_head], 0
	mov	byte [cs:dsr_len], 0
	jmp	.read_store
.read_no_dsr:
	; Next: drain queued scan code from a previous extended key.
	mov	al, [cs:pending_scan]
	or	al, al
	jz	.read_no_pending
	mov	byte [cs:pending_scan], 0
	jmp	.read_store
.read_no_pending:
	mov	ah, 0x00
	int	0x16
	or	al, al
	jnz	.read_store
	; Extended key (AL=0, AH=scancode): emit NUL now, queue scancode.
	mov	[cs:pending_scan], ah
.read_store:
	stosb
	inc	dx
	loop	.read_loop
.read_done:
	pop	es
	mov	bx, [cs:req_ptr]
	mov	[es:bx+18], dx
	mov	word [es:bx+3], REQ_DONE
	jmp	.done

.nd_read:
	; Pending DSR response byte? Peek returns it.
	cmp	byte [cs:dsr_len], 0
	je	.nd_no_dsr
	push	bx
	xor	bh, bh
	mov	bl, [cs:dsr_head]
	mov	al, [cs:dsr_buf+bx]
	pop	bx
	jmp	.nd_have_byte
.nd_no_dsr:
	; Pending extended-key scan code? Peek returns it.
	mov	al, [cs:pending_scan]
	or	al, al
	jnz	.nd_have_byte
	mov	ah, 0x01
	int	0x16
	jz	.nd_none
	; AL is what READ would deliver next (NUL for extended, ASCII otherwise).
.nd_have_byte:
	mov	[es:bx+13], al
	mov	word [es:bx+3], REQ_DONE
	jmp	.done
.nd_none:
	mov	word [es:bx+3], REQ_BUSY
	jmp	.done

.in_status:
	cmp	byte [cs:dsr_len], 0
	jne	.in_status_ready
	cmp	byte [cs:pending_scan], 0
	jne	.in_status_ready
	mov	ah, 0x01
	int	0x16
	jz	.in_not_ready
.in_status_ready:
	mov	word [es:bx+3], REQ_DONE
	jmp	.done
.in_not_ready:
	mov	word [es:bx+3], REQ_BUSY
	jmp	.done

.in_flush:
	mov	byte [cs:pending_scan], 0
	mov	byte [cs:dsr_head], 0
	mov	byte [cs:dsr_len], 0
.in_flush_loop:
	mov	ah, 0x01
	int	0x16
	jz	.flush_done
	mov	ah, 0x00
	int	0x16
	jmp	.in_flush_loop
.flush_done:
	mov	word [es:bx+3], REQ_DONE
	jmp	.done

.write:
	cld
	mov	cx, [es:bx+18]
	mov	si, [es:bx+14]
	mov	ax, [es:bx+16]
	push	ds
	mov	ds, ax
	xor	dx, dx
.write_loop:
	jcxz	.write_done
	lodsb
	call	ansi_process_char
	inc	dx
	loop	.write_loop
.write_done:
	pop	ds
	mov	es, [cs:req_seg]
	mov	bx, [cs:req_ptr]
	mov	[es:bx+18], dx
	mov	word [es:bx+3], REQ_DONE
	jmp	.done

.out_status:
	mov	word [es:bx+3], REQ_DONE

.done:
	pop	es
	pop	ds
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	retf

; ============================================================================
; ANSI parser
; ============================================================================
ansi_process_char:
	push	ax
	push	bx
	push	cx
	push	dx
	push	si
	push	di
	push	es

	mov	[cs:ansi_char], al

.again:
	mov	al, [cs:ansi_char]
	cmp	byte [cs:ansi_state], 0
	je	.normal
	cmp	byte [cs:ansi_state], 1
	je	.esc_seen
	jmp	.csi_seen

.normal:
	cmp	al, ESC
	jne	.normal_char
	mov	byte [cs:ansi_state], 1
	jmp	.done
.normal_char:
	call	ansi_put_char
	jmp	.done

.esc_seen:
	cmp	al, '['
	je	.start_csi
	; Unknown ESC sequence: print the ESC, then handle this byte normally.
	mov	byte [cs:ansi_state], 0
	mov	al, ESC
	call	ansi_put_char
	jmp	.again

.start_csi:
	call	ansi_csi_clear
	mov	byte [cs:ansi_state], 2
	jmp	.done

.csi_seen:
	cmp	al, '?'
	je	.done			; Private mode marker: accept, ignore
	cmp	al, '0'
	jb	.not_digit
	cmp	al, '9'
	ja	.not_digit
	call	ansi_csi_digit
	jmp	.done
.not_digit:
	cmp	al, ';'
	je	.next_param
	cmp	al, 0x40
	jb	.done
	cmp	al, 0x7E
	ja	.reset
	mov	byte [cs:ansi_state], 0
	call	ansi_exec_csi
	jmp	.done
.next_param:
	cmp	byte [cs:ansi_param_idx], 7
	jae	.done
	inc	byte [cs:ansi_param_idx]
	jmp	.done
.reset:
	mov	byte [cs:ansi_state], 0

.done:
	pop	es
	pop	di
	pop	si
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

ansi_csi_clear:
	push	ax
	push	cx
	push	di
	xor	ax, ax
	mov	byte [cs:ansi_param_idx], 0
	mov	di, ansi_params
	mov	cx, 8
.loop:
	mov	[cs:di], ax
	add	di, 2
	loop	.loop
	pop	di
	pop	cx
	pop	ax
	ret

ansi_csi_digit:
	push	ax
	push	bx
	push	dx
	sub	al, '0'
	xor	ah, ah
	push	ax			; Save digit
	xor	bh, bh
	mov	bl, [cs:ansi_param_idx]
	shl	bx, 1
	mov	ax, [cs:ansi_params+bx]
	shl	ax, 1			; AX = old * 2
	mov	dx, [cs:ansi_params+bx]
	shl	dx, 1
	shl	dx, 1
	shl	dx, 1			; DX = old * 8
	add	ax, dx
	pop	dx			; DX = digit
	xor	dh, dh
	add	ax, dx			; AX = old * 10 + digit
	mov	[cs:ansi_params+bx], ax
	pop	dx
	pop	bx
	pop	ax
	ret

; AL = final CSI byte
ansi_exec_csi:
	cmp	al, 'A'
	je	ansi_cursor_up
	cmp	al, 'B'
	je	ansi_cursor_down
	cmp	al, 'C'
	je	ansi_cursor_right
	cmp	al, 'D'
	je	ansi_cursor_left
	cmp	al, 'H'
	je	ansi_cursor_pos
	cmp	al, 'f'
	je	ansi_cursor_pos
	cmp	al, 'J'
	je	ansi_erase_display
	cmp	al, 'K'
	je	ansi_erase_line
	cmp	al, 'm'
	je	ansi_sgr
	cmp	al, 's'
	je	ansi_save_cursor
	cmp	al, 'u'
	je	ansi_restore_cursor
	cmp	al, 'n'
	je	ansi_dsr
	ret

; ESC[6n — Device Status Report. Queues "ESC[<row>;<col>R" for the input side.
ansi_dsr:
	mov	ax, [cs:ansi_params]
	cmp	ax, 6
	jne	.dsr_ignore
	call	ansi_dsr_build
.dsr_ignore:
	ret

; Build the DSR response into dsr_buf and prime the queue.
ansi_dsr_build:
	push	ax
	push	bx
	push	cx
	push	dx
	call	ansi_get_cursor
	mov	byte [cs:dsr_buf+0], ESC
	mov	byte [cs:dsr_buf+1], '['
	mov	bx, dsr_buf + 2
	mov	al, [cs:ansi_row]
	inc	al			; ANSI is 1-based
	call	ansi_dsr_emit_decimal
	mov	byte [cs:bx], ';'
	inc	bx
	mov	al, [cs:ansi_col]
	inc	al
	call	ansi_dsr_emit_decimal
	mov	byte [cs:bx], 'R'
	inc	bx
	sub	bx, dsr_buf
	mov	[cs:dsr_len], bl
	mov	byte [cs:dsr_head], 0
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; AL = byte value (0-99), BX = CS-relative buffer pointer.
; Writes 1 or 2 ASCII digits, advances BX.
ansi_dsr_emit_decimal:
	push	ax
	push	dx
	xor	ah, ah
	mov	dl, 10
	div	dl			; AL = tens, AH = ones
	or	al, al
	jz	.dsr_one
	add	al, '0'
	mov	[cs:bx], al
	inc	bx
.dsr_one:
	mov	al, ah
	add	al, '0'
	mov	[cs:bx], al
	inc	bx
	pop	dx
	pop	ax
	ret

; ============================================================================
; Console output helpers
; ============================================================================
ansi_put_char:
	cmp	al, 0x0D
	je	ansi_cr
	cmp	al, 0x0A
	je	ansi_lf
	cmp	al, 0x08
	je	ansi_bs
	cmp	al, 0x09
	je	ansi_tab
	cmp	al, 0x07
	je	ansi_bel
	cmp	al, 0x20
	jb	.put_done

	mov	[cs:ansi_char], al
	mov	ah, 0x09
	mov	al, [cs:ansi_char]
	xor	bh, bh
	mov	bl, [cs:ansi_attr]
	mov	cx, 1
	int	0x10
	call	ansi_advance_cursor
.put_done:
	ret

ansi_cr:
	call	ansi_get_cursor
	mov	byte [cs:ansi_col], 0
	jmp	ansi_set_cursor_vars

ansi_lf:
	call	ansi_get_cursor
	inc	byte [cs:ansi_row]
	cmp	byte [cs:ansi_row], ROWS
	jb	ansi_set_cursor_vars
	call	ansi_scroll_up_one
	mov	byte [cs:ansi_row], ROWS-1
	jmp	ansi_set_cursor_vars

ansi_bs:
	call	ansi_get_cursor
	cmp	byte [cs:ansi_col], 0
	je	.bs_done
	dec	byte [cs:ansi_col]
	call	ansi_set_cursor_vars
.bs_done:
	ret

ansi_tab:
	call	ansi_get_cursor
.tab_loop:
	mov	al, ' '
	call	ansi_put_char
	call	ansi_get_cursor
	mov	al, [cs:ansi_col]
	and	al, 7
	jnz	.tab_loop
	ret

ansi_bel:
	ret

ansi_advance_cursor:
	call	ansi_get_cursor
	inc	byte [cs:ansi_col]
	cmp	byte [cs:ansi_col], COLS
	jb	ansi_set_cursor_vars
	mov	byte [cs:ansi_col], 0
	inc	byte [cs:ansi_row]
	cmp	byte [cs:ansi_row], ROWS
	jb	ansi_set_cursor_vars
	call	ansi_scroll_up_one
	mov	byte [cs:ansi_row], ROWS-1
	jmp	ansi_set_cursor_vars

ansi_scroll_up_one:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	ah, 0x06
	mov	al, 1
	mov	bh, [cs:ansi_attr]
	xor	cx, cx
	mov	dx, 0x184F
	int	0x10
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

ansi_get_cursor:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	ah, 0x03
	xor	bh, bh
	int	0x10
	mov	[cs:ansi_row], dh
	mov	[cs:ansi_col], dl
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

ansi_set_cursor_vars:
	push	ax
	push	bx
	push	dx
	mov	ah, 0x02
	xor	bh, bh
	mov	dh, [cs:ansi_row]
	mov	dl, [cs:ansi_col]
	int	0x10
	pop	dx
	pop	bx
	pop	ax
	ret

; ============================================================================
; CSI cursor commands
; ============================================================================
ansi_param0_default1:
	mov	ax, [cs:ansi_params]
	or	ax, ax
	jnz	.pdone
	inc	ax
.pdone:
	ret

ansi_cursor_up:
	call	ansi_get_cursor
	call	ansi_param0_default1
	cmp	ax, ROWS
	jbe	.up_count_ok
	mov	ax, ROWS
.up_count_ok:
	cmp	[cs:ansi_row], al
	jb	.up_home
	sub	[cs:ansi_row], al
	jmp	ansi_set_cursor_vars
.up_home:
	mov	byte [cs:ansi_row], 0
	jmp	ansi_set_cursor_vars

ansi_cursor_down:
	call	ansi_get_cursor
	call	ansi_param0_default1
	cmp	ax, ROWS
	jbe	.down_count_ok
	mov	ax, ROWS
.down_count_ok:
	add	al, [cs:ansi_row]
	cmp	al, ROWS-1
	jbe	.down_ok
	mov	al, ROWS-1
.down_ok:
	mov	[cs:ansi_row], al
	jmp	ansi_set_cursor_vars

ansi_cursor_right:
	call	ansi_get_cursor
	call	ansi_param0_default1
	cmp	ax, COLS
	jbe	.right_count_ok
	mov	ax, COLS
.right_count_ok:
	add	al, [cs:ansi_col]
	cmp	al, COLS-1
	jbe	.right_ok
	mov	al, COLS-1
.right_ok:
	mov	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars

ansi_cursor_left:
	call	ansi_get_cursor
	call	ansi_param0_default1
	cmp	ax, COLS
	jbe	.left_count_ok
	mov	ax, COLS
.left_count_ok:
	cmp	[cs:ansi_col], al
	jb	.left_home
	sub	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars
.left_home:
	mov	byte [cs:ansi_col], 0
	jmp	ansi_set_cursor_vars

ansi_cursor_pos:
	mov	ax, [cs:ansi_params]
	or	ax, ax
	jnz	.row_nonzero
	inc	ax
.row_nonzero:
	cmp	ax, ROWS
	jbe	.row_ok
	mov	ax, ROWS
.row_ok:
	dec	al
	mov	[cs:ansi_row], al

	mov	ax, [cs:ansi_params+2]
	or	ax, ax
	jnz	.col_nonzero
	inc	ax
.col_nonzero:
	cmp	ax, COLS
	jbe	.col_ok
	mov	ax, COLS
.col_ok:
	dec	al
	mov	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars

ansi_save_cursor:
	call	ansi_get_cursor
	mov	al, [cs:ansi_row]
	mov	[cs:saved_row], al
	mov	al, [cs:ansi_col]
	mov	[cs:saved_col], al
	ret

ansi_restore_cursor:
	mov	al, [cs:saved_row]
	mov	[cs:ansi_row], al
	mov	al, [cs:saved_col]
	mov	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars

; ============================================================================
; CSI erase commands
; ============================================================================
ansi_erase_line:
	call	ansi_get_cursor
	mov	al, [cs:ansi_row]
	mov	[cs:ansi_save_row], al
	mov	al, [cs:ansi_col]
	mov	[cs:ansi_save_col], al
	mov	ax, [cs:ansi_params]
	cmp	ax, 1
	je	.el_start
	cmp	ax, 2
	je	.el_all
	; 0 or unsupported: cursor to end
	mov	dh, [cs:ansi_save_row]
	mov	dl, [cs:ansi_save_col]
	mov	cx, COLS
	xor	ax, ax
	mov	al, dl
	sub	cx, ax
	jmp	.el_blank
.el_start:
	mov	dh, [cs:ansi_save_row]
	xor	dl, dl
	xor	cx, cx
	mov	cl, [cs:ansi_save_col]
	inc	cx
	jmp	.el_blank
.el_all:
	mov	dh, [cs:ansi_save_row]
	xor	dl, dl
	mov	cx, COLS
.el_blank:
	call	ansi_blank_at
	mov	al, [cs:ansi_save_row]
	mov	[cs:ansi_row], al
	mov	al, [cs:ansi_save_col]
	mov	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars

ansi_erase_display:
	call	ansi_get_cursor
	mov	al, [cs:ansi_row]
	mov	[cs:ansi_save_row], al
	mov	al, [cs:ansi_col]
	mov	[cs:ansi_save_col], al
	mov	ax, [cs:ansi_params]
	cmp	ax, 1
	je	.ed_start
	cmp	ax, 2
	je	.ed_all
	; 0 or unsupported: cursor to end of screen
	call	ansi_erase_line
	mov	al, [cs:ansi_save_row]
	inc	al
	jmp	.ed_clear_rows_to_end
.ed_start:
	xor	al, al
.ed_start_loop:
	cmp	al, [cs:ansi_save_row]
	jae	.ed_start_last
	push	ax
	mov	dh, al
	xor	dl, dl
	mov	cx, COLS
	call	ansi_blank_at
	pop	ax
	inc	al
	jmp	.ed_start_loop
.ed_start_last:
	mov	dh, [cs:ansi_save_row]
	xor	dl, dl
	xor	cx, cx
	mov	cl, [cs:ansi_save_col]
	inc	cx
	call	ansi_blank_at
	jmp	.ed_restore
.ed_all:
	xor	al, al
.ed_clear_rows_to_end:
	cmp	al, ROWS
	jae	.ed_restore
	push	ax
	mov	dh, al
	xor	dl, dl
	mov	cx, COLS
	call	ansi_blank_at
	pop	ax
	inc	al
	jmp	.ed_clear_rows_to_end
.ed_restore:
	mov	al, [cs:ansi_save_row]
	mov	[cs:ansi_row], al
	mov	al, [cs:ansi_save_col]
	mov	[cs:ansi_col], al
	jmp	ansi_set_cursor_vars

; DH=row, DL=col, CX=count
ansi_blank_at:
	jcxz	.blank_done
	push	ax
	push	bx
	push	cx
	push	dx
	mov	[cs:ansi_row], dh
	mov	[cs:ansi_col], dl
	call	ansi_set_cursor_vars
	mov	ah, 0x09
	mov	al, ' '
	xor	bh, bh
	mov	bl, [cs:ansi_attr]
	int	0x10
	pop	dx
	pop	cx
	pop	bx
	pop	ax
.blank_done:
	ret

; ============================================================================
; CSI SGR colors/attributes
; ============================================================================
ansi_sgr:
	xor	si, si
	xor	ch, ch
	mov	cl, [cs:ansi_param_idx]
	inc	cx
.loop:
	push	cx
	mov	bx, si
	shl	bx, 1
	mov	ax, [cs:ansi_params+bx]
	call	ansi_sgr_one
	inc	si
	pop	cx
	loop	.loop
	ret

ansi_sgr_one:
	cmp	ax, 0
	je	.sgr_reset
	cmp	ax, 1
	je	.sgr_bright
	cmp	ax, 5
	je	.sgr_blink
	cmp	ax, 7
	je	.sgr_reverse
	cmp	ax, 22
	je	.sgr_normal_intensity
	cmp	ax, 25
	je	.sgr_no_blink
	cmp	ax, 30
	jb	.sgr_done
	cmp	ax, 37
	jbe	.sgr_fg
	cmp	ax, 39
	je	.sgr_fg_default
	cmp	ax, 40
	jb	.sgr_done
	cmp	ax, 47
	jbe	.sgr_bg
	cmp	ax, 49
	je	.sgr_bg_default
	ret
.sgr_reset:
	mov	byte [cs:ansi_attr], 0x07
	ret
.sgr_bright:
	or	byte [cs:ansi_attr], 0x08
	ret
.sgr_normal_intensity:
	and	byte [cs:ansi_attr], 0xF7
	ret
.sgr_blink:
	or	byte [cs:ansi_attr], 0x80
	ret
.sgr_no_blink:
	and	byte [cs:ansi_attr], 0x7F
	ret
.sgr_reverse:
	mov	al, [cs:ansi_attr]
	mov	ah, al
	and	al, 0x07
	shl	al, 1
	shl	al, 1
	shl	al, 1
	shl	al, 1
	and	ah, 0x70
	shr	ah, 1
	shr	ah, 1
	shr	ah, 1
	shr	ah, 1
	or	al, ah
	mov	ah, [cs:ansi_attr]
	and	ah, 0x88
	or	al, ah
	mov	[cs:ansi_attr], al
	ret
.sgr_fg_default:
	and	byte [cs:ansi_attr], 0xF8
	or	byte [cs:ansi_attr], 0x07
	ret
.sgr_bg_default:
	and	byte [cs:ansi_attr], 0x8F
	ret
.sgr_fg:
	sub	al, 30
	xor	bh, bh
	mov	bl, al
	mov	al, [cs:ansi_color_table+bx]
	mov	bl, [cs:ansi_attr]
	and	bl, 0xF8
	or	bl, al
	mov	[cs:ansi_attr], bl
	ret
.sgr_bg:
	sub	al, 40
	xor	bh, bh
	mov	bl, al
	mov	al, [cs:ansi_color_table+bx]
	shl	al, 1
	shl	al, 1
	shl	al, 1
	shl	al, 1
	mov	bl, [cs:ansi_attr]
	and	bl, 0x8F
	or	bl, al
	mov	[cs:ansi_attr], bl
.sgr_done:
	ret

; ANSI color order: black, red, green, yellow, blue, magenta, cyan, white
; CGA color order:  black, blue, green, cyan, red, magenta, brown, white
ansi_color_table:
	db	0, 4, 2, 6, 1, 5, 3, 7

; Print the install banner via BIOS TTY (INT 10h AH=0Eh). Goes directly to
; video so it works during INIT before our driver is linked into the chain.
; Uses CS-relative reads so it doesn't depend on caller's DS.
ansi_init_banner:
	push	ax
	push	bx
	push	si
	mov	si, banner_msg
.bp_loop:
	mov	al, [cs:si]
	or	al, al
	jz	.bp_done
	mov	ah, 0x0E
	xor	bh, bh
	int	0x10
	inc	si
	jmp	.bp_loop
.bp_done:
	pop	si
	pop	bx
	pop	ax
	ret

; ============================================================================
; Resident data
; ============================================================================
req_ptr:	dw	0
req_seg:	dw	0
ansi_state:	db	0		; 0 normal, 1 ESC, 2 CSI
ansi_attr:	db	0x07
ansi_char:	db	0
ansi_param_idx: db	0
ansi_params:	times 8 dw 0
ansi_row:	db	0
ansi_col:	db	0
ansi_save_row:	db	0
ansi_save_col:	db	0
saved_row:	db	0
saved_col:	db	0
pending_scan:	db	0		; scan code queued from last extended key
					; (BIOS returns AL=0 + AH=scan; we report
					; NUL first, then scan on next read)
dsr_buf:	times 12 db 0		; Pending DSR (cursor position) response,
					; format ESC [ row ; col R (max 9 bytes)
dsr_head:	db	0		; next byte index to deliver
dsr_len:	db	0		; total bytes queued (0 = empty)

banner_msg:	db	'MegaDOS ANSI driver installed', 0x0D, 0x0A, 0

resident_end:
