; EDIT.COM - Basic fullscreen text editor for MegaDOS
; Usage: EDIT [file]
;
; Controls:
;   Arrow keys  Move cursor
;   Home/End    Start/end of line
;   Enter       Split line
;   Backspace   Delete left / delete at previous row end
;   Del         Delete at cursor / join with next line
;   Tab         Insert 4 spaces
;   F2          Save
;   Esc         Exit

	cpu	8086
	org	0x0100

COLS		equ	80
VIEW_ROWS	equ	24
MAX_LINES	equ	300
LINE_BYTES	equ	COLS
BUF_BYTES	equ	(MAX_LINES * LINE_BYTES)
MAX_NAME	equ	63

start:
	cld
	call	fix_segs
	call	parse_cmdline
	call	clear_all_lines
	call	load_file
	call	ensure_cursor_visible
	call	clear_screen
	call	redraw_screen

editor_loop:
	call	fix_segs
	call	clamp_cursor

	xor	ah, ah
	int	0x16

	cmp	al, 0
	jne	.ascii_key

	cmp	ah, 0x48		; Up
	je	key_up
	cmp	ah, 0x50		; Down
	je	key_down
	cmp	ah, 0x4B		; Left
	je	key_left
	cmp	ah, 0x4D		; Right
	je	key_right
	cmp	ah, 0x47		; Home
	je	key_home
	cmp	ah, 0x4F		; End
	je	key_end
	cmp	ah, 0x49		; PgUp
	je	key_pgup
	cmp	ah, 0x51		; PgDn
	je	key_pgdn
	cmp	ah, 0x53		; Del
	je	key_delete
	jmp	editor_loop

.ascii_key:
	cmp	al, 27			; Esc
	je	key_exit
	cmp	al, 8			; Backspace
	je	key_backspace
	cmp	al, 13			; Enter
	je	key_enter
	cmp	al, 9			; Tab
	je	key_tab
	cmp	al, 19			; Ctrl-S
	je	key_save
	cmp	al, 24			; Ctrl-X
	je	key_save_exit
	cmp	al, 32
	jb	editor_loop
	cmp	al, 126
	ja	editor_loop
	call	insert_char
	cmp	byte [need_full_redraw], 0
	jne	.ak_full
	cmp	byte [need_line_redraw], 0
	jne	.ak_redraw
	call	paint_last_char
	call	redraw_status_only
	call	position_cursor
	jmp	editor_loop
.ak_full:
	call	redraw_screen
	jmp	editor_loop
.ak_redraw:
	call	redraw_current_line
	call	redraw_status_only
	call	position_cursor
	jmp	editor_loop

key_up:
	cmp	word [cur_line], 0
	je	editor_loop
	mov	ax, [top_line]
	mov	[tmp_top], ax
	dec	word [cur_line]
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	call	refresh_after_move
	jmp	editor_loop

key_down:
	mov	ax, [line_count]
	dec	ax
	cmp	[cur_line], ax
	jae	editor_loop
	mov	ax, [top_line]
	mov	[tmp_top], ax
	inc	word [cur_line]
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	call	refresh_after_move
	jmp	editor_loop

key_left:
	cmp	word [cur_col], 0
	jne	.left_dec
	cmp	word [cur_line], 0
	je	editor_loop
	mov	ax, [top_line]
	mov	[tmp_top], ax
	dec	word [cur_line]
	; Position at end of previous line, not hard-coded col 79.
	mov	ax, [cur_line]
	call	get_line_info
	mov	ax, cx
	cmp	ax, COLS - 1
	jbe	.kl_set
	mov	ax, COLS - 1
.kl_set:
	mov	[cur_col], ax
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	call	refresh_after_move
	jmp	editor_loop
.left_dec:
	dec	word [cur_col]
	mov	word [status_ptr], msg_help
	call	refresh_status_cursor
	jmp	editor_loop

key_right:
	; At col 79 there is nowhere further right on this line — always
	; wrap to the next line (if one exists). Otherwise a full line
	; would trap the cursor at col 79 forever.
	mov	ax, [cur_col]
	cmp	ax, COLS - 1
	jae	.kr_wrap
	; Not at col 79. If still within the line's data, just advance.
	mov	ax, [cur_line]
	call	get_line_info
	mov	ax, [cur_col]
	cmp	ax, cx
	jb	.kr_inc
.kr_wrap:
	mov	ax, [line_count]
	dec	ax
	cmp	[cur_line], ax
	jae	editor_loop
	mov	ax, [top_line]
	mov	[tmp_top], ax
	inc	word [cur_line]
	mov	word [cur_col], 0
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	call	refresh_after_move
	jmp	editor_loop
.kr_inc:
	inc	word [cur_col]
	mov	word [status_ptr], msg_help
	call	refresh_status_cursor
	jmp	editor_loop

key_home:
	mov	word [cur_col], 0
	mov	word [status_ptr], msg_help
	call	refresh_status_cursor
	jmp	editor_loop

key_end:
	mov	ax, [cur_line]
	call	get_line_info
	mov	ax, cx
	cmp	ax, COLS - 1
	jbe	.end_set
	mov	ax, COLS - 1
.end_set:
	mov	[cur_col], ax
	mov	word [status_ptr], msg_help
	call	refresh_status_cursor
	jmp	editor_loop

key_pgup:
	cmp	word [top_line], 0
	je	editor_loop
	mov	ax, [top_line]
	cmp	ax, VIEW_ROWS
	jb	.pgup_top
	sub	ax, VIEW_ROWS
	jmp	.pgup_set
.pgup_top:
	xor	ax, ax
.pgup_set:
	mov	[top_line], ax
	mov	[cur_line], ax
	mov	word [status_ptr], msg_help
	call	redraw_screen
	jmp	editor_loop

key_pgdn:
	mov	ax, [line_count]
	cmp	ax, VIEW_ROWS
	jbe	editor_loop
	mov	dx, ax
	sub	dx, VIEW_ROWS
	mov	ax, [top_line]
	add	ax, VIEW_ROWS
	cmp	ax, dx
	jbe	.pgdn_keep
	mov	ax, dx
.pgdn_keep:
	mov	[top_line], ax
	mov	[cur_line], ax
	mov	word [status_ptr], msg_help
	call	redraw_screen
	jmp	editor_loop

key_backspace:
	call	backspace_key
	call	redraw_screen
	jmp	editor_loop

key_delete:
	call	delete_key
	call	redraw_screen
	jmp	editor_loop

key_enter:
	call	split_line
	call	ensure_cursor_visible
	call	redraw_screen
	jmp	editor_loop

key_tab:
	mov	al, ' '
	call	insert_char
	mov	al, ' '
	call	insert_char
	mov	al, ' '
	call	insert_char
	mov	al, ' '
	call	insert_char
	call	redraw_current_line
	call	redraw_status_only
	call	position_cursor
	jmp	editor_loop

key_save:
	call	save_file
	call	redraw_status_only
	call	position_cursor
	jmp	editor_loop

key_save_exit:
	call	save_file
	cmp	byte [save_failed], 0
	jne	editor_loop
	jmp	key_exit

key_exit:
	call	clear_screen
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; Editing
; ============================================================================

insert_char:
	mov	[tmp_char], al
	mov	byte [need_line_redraw], 0
	mov	byte [need_full_redraw], 0
	mov	byte [tried_wrap], 0
.ic_retry:
	mov	ax, [cur_line]
	mov	[last_paint_line], ax
	mov	ax, [cur_col]
	mov	[last_paint_col], ax
	mov	ax, [cur_line]
	call	get_line_info		; DI=line ptr, CX=len
	mov	dx, [cur_col]
	cmp	dx, COLS - 1
	jbe	.ic_col_ok
	mov	dx, COLS - 1
	mov	[cur_col], dx
.ic_col_ok:
	cmp	dx, cx
	ja	.ic_gap_store
	cmp	cx, COLS
	jae	.ic_overwrite
	mov	byte [need_line_redraw], 1
	mov	bx, di
	mov	si, cx
.ic_shift:
	cmp	si, dx
	jbe	.ic_store
	mov	al, [bx + si - 1]
	mov	[bx + si], al
	dec	si
	jmp	.ic_shift
.ic_store:
	mov	al, [tmp_char]
	mov	si, dx
	mov	[bx + si], al
	inc	word [cur_col]
	call	advance_after_insert
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret
.ic_gap_store:
	mov	bx, di
	mov	al, [tmp_char]
	mov	si, dx
	mov	[bx + si], al
	inc	word [cur_col]
	call	advance_after_insert
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret
.ic_overwrite:
	; Line is full (80 chars).
	; If we're at col 79 (end of line), auto-wrap: split the line here so
	; the byte at col 79 moves to a fresh next line, then re-enter the
	; insert logic to place the new char at col 0 of that new line.
	; Anywhere else on a full line, refuse (beep) — there's no room and
	; silently dropping the last character would lose user data.
	cmp	byte [tried_wrap], 0
	jne	.ic_refuse
	mov	ax, [cur_col]
	cmp	ax, COLS - 1
	jb	.ic_refuse
	mov	ax, [line_count]
	cmp	ax, MAX_LINES
	jae	.ic_refuse
	mov	byte [tried_wrap], 1
	call	split_line
	mov	byte [need_full_redraw], 1
	jmp	.ic_retry
.ic_refuse:
	call	beep
	mov	byte [need_line_redraw], 1
	mov	word [status_ptr], msg_help
	ret

advance_after_insert:
	cmp	word [cur_col], COLS
	jb	.aai_done
	mov	word [cur_col], 0
	mov	ax, [cur_line]
	inc	ax
	cmp	ax, MAX_LINES
	jae	.aai_last
	cmp	ax, [line_count]
	jb	.aai_move
	inc	word [line_count]
.aai_move:
	inc	word [cur_line]
	mov	ax, [top_line]
	mov	[tmp_top], ax
	call	ensure_cursor_visible
	; Force full redraw whenever we wrap. The caller's stored char landed
	; on the OLD line (last_paint_line), but cur_line now points to the
	; NEW line — a plain redraw_current_line would redraw the wrong row
	; and paint_last_char is skipped when any redraw flag is set.
	mov	byte [need_full_redraw], 1
	ret
.aai_last:
	mov	word [cur_col], COLS - 1
.aai_done:
	ret

backspace_key:
	mov	ax, [cur_col]
	cmp	ax, 0
	je	.bk_prev_row

	dec	ax
	mov	[cur_col], ax
	mov	dx, ax
	mov	ax, [cur_line]
	call	get_line_info		; DI=line ptr, CX=len
	cmp	dx, cx
	jae	.bk_done
	mov	bx, di
	mov	si, dx
.bk_shift:
	mov	ax, si
	inc	ax
	cmp	ax, cx
	jae	.bk_clear
	mov	al, [bx + si + 1]
	mov	[bx + si], al
	inc	si
	jmp	.bk_shift
.bk_clear:
	mov	si, cx
	dec	si
	mov	byte [bx + si], ' '
.bk_done:
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret

.bk_prev_row:
	cmp	word [cur_line], 0
	je	.bk_done_noop

	; Remember current line's length (used below to detect auto-wrap).
	mov	ax, [cur_line]
	call	get_line_info
	mov	[tmp_prev_len], cx	; stash curr_len

	mov	ax, [top_line]
	mov	[tmp_top], ax
	dec	word [cur_line]

	; Get prev line length (CX)
	mov	ax, [cur_line]
	call	get_line_info

	; Auto-wrap undo:
	;   prev line has exactly 80 chars AND current line is empty.
	; Only auto-wrap (typing at col 79) leaves that exact state — a
	; split via Enter always shrinks the prev line below 80. So when we
	; see it, undo the wrap: remove the empty curr line and clear the
	; just-typed byte at col 79 of the prev line.
	cmp	word [tmp_prev_len], 0
	jne	.bk_normal_join
	cmp	cx, COLS
	jne	.bk_normal_join

	mov	ax, [cur_line]
	inc	ax
	call	shift_up_from_ax	; remove empty line
	mov	ax, [cur_line]
	call	get_line_ptr_di
	mov	byte [di + COLS - 1], ' '
	mov	word [cur_col], COLS - 1
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	ret

.bk_normal_join:
	; Normal case: position at end of prev line data (length) and join
	; the lines via delete_key. CX is still the prev line length.
	mov	[cur_col], cx
	mov	word [status_ptr], msg_help
	call	ensure_cursor_visible
	call	delete_key
	cmp	word [cur_col], COLS - 1
	jbe	.bk_done_noop
	mov	word [cur_col], COLS - 1
.bk_done_noop:
	ret

delete_key:
	mov	ax, [cur_line]
	call	get_line_info		; DI=line ptr, CX=len
	mov	[tmp_len], cx
	mov	[tmp_ptr], di
	mov	dx, [cur_col]
	cmp	dx, cx
	jae	.dk_join

	mov	bx, di
	mov	si, dx
.dk_shift:
	mov	ax, si
	inc	ax
	cmp	ax, cx
	jae	.dk_clear
	mov	al, [bx + si + 1]
	mov	[bx + si], al
	inc	si
	jmp	.dk_shift
.dk_clear:
	mov	si, cx
	dec	si
	mov	byte [bx + si], ' '
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret

.dk_join:
	mov	ax, [line_count]
	dec	ax
	cmp	[cur_line], ax
	jae	beep

	mov	ax, [cur_line]
	inc	ax
	call	get_line_info
	mov	[tmp_next_len], cx
	mov	[tmp_ptr2], di

	mov	ax, [tmp_len]
	add	ax, [tmp_next_len]
	cmp	ax, COLS
	ja	beep

	mov	di, [tmp_ptr]
	add	di, [tmp_len]
	mov	si, [tmp_ptr2]
	mov	cx, [tmp_next_len]
	cld
	rep	movsb

	mov	ax, [cur_line]
	inc	ax
	call	shift_up_from_ax
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret

split_line:
	cmp	word [line_count], MAX_LINES
	jae	beep

	mov	ax, [cur_line]
	call	get_line_info
	mov	[tmp_len], cx
	mov	[tmp_ptr], di
	mov	bx, [cur_col]
	cmp	bx, cx
	jbe	.sl_col_ok
	mov	bx, cx
	mov	[cur_col], bx
.sl_col_ok:
	mov	ax, [cur_line]
	inc	ax
	call	shift_down_from_ax
	jc	beep

	mov	ax, [cur_line]
	inc	ax
	call	get_line_ptr_di
	mov	[tmp_ptr2], di

	mov	si, [tmp_ptr]
	add	si, bx
	mov	di, [tmp_ptr2]
	mov	cx, [tmp_len]
	sub	cx, bx
	jbe	.sl_clear_old
	cld
	rep	movsb

.sl_clear_old:
	mov	di, [tmp_ptr]
	add	di, bx
	mov	cx, COLS
	sub	cx, bx
	mov	al, ' '
	cld
	rep	stosb

	inc	word [cur_line]
	mov	word [cur_col], 0
	mov	byte [dirty], 1
	mov	word [status_ptr], msg_help
	ret

; ============================================================================
; File I/O
; ============================================================================

load_file:
	call	fix_segs
	mov	word [line_count], 1
	mov	word [cur_line], 0
	mov	word [cur_col], 0
	mov	word [top_line], 0
	mov	byte [dirty], 0
	mov	word [load_line], 0
	mov	word [load_col], 0
	mov	byte [load_last_cr], 0
	mov	word [status_ptr], msg_new

	mov	ah, 0x3D
	mov	al, 0
	mov	dx, filename
	int	0x21
	jc	.lf_new
	mov	[file_handle], ax
	call	fix_segs

.lf_read:
	mov	ah, 0x3F
	mov	bx, [file_handle]
	mov	cx, 512
	mov	dx, readbuf
	int	0x21
	jc	.lf_close
	or	ax, ax
	jz	.lf_close
	call	fix_segs
	mov	[tmp_len], ax
	mov	si, readbuf

.lf_parse:
	cmp	word [tmp_len], 0
	je	.lf_read
	lodsb
	dec	word [tmp_len]

	cmp	byte [load_last_cr], 0
	je	.lf_check_char
	mov	byte [load_last_cr], 0
	cmp	al, 0x0A
	je	.lf_parse

.lf_check_char:
	cmp	al, 0x1A
	je	.lf_close
	cmp	al, 0x0D
	je	.lf_cr
	cmp	al, 0x0A
	je	.lf_nl
	cmp	al, 9
	je	.lf_tab
	cmp	al, 32
	jb	.lf_parse
	call	load_append_char
	jmp	.lf_parse

.lf_cr:
	mov	byte [load_last_cr], 1
.lf_nl:
	call	load_newline
	jmp	.lf_parse

.lf_tab:
	mov	al, ' '
	call	load_append_char
	mov	al, ' '
	call	load_append_char
	mov	al, ' '
	call	load_append_char
	mov	al, ' '
	call	load_append_char
	jmp	.lf_parse

.lf_close:
	push	ax
	mov	ah, 0x3E
	mov	bx, [file_handle]
	int	0x21
	call	fix_segs
	pop	ax
	mov	word [status_ptr], msg_loaded
	ret

.lf_new:
	mov	word [status_ptr], msg_new
	ret

save_file:
	call	fix_segs
	mov	byte [save_failed], 0
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, filename
	int	0x21
	jc	.sf_fail
	mov	[file_handle], ax
	call	fix_segs
	mov	word [tmp_index], 0

.sf_loop:
	mov	bx, [tmp_index]
	cmp	bx, [line_count]
	jae	.sf_close_ok

	mov	ax, bx
	call	get_line_info
	mov	[tmp_len], cx
	mov	[tmp_ptr], di
	cmp	cx, 0
	je	.sf_after_text

	mov	ah, 0x40
	mov	bx, [file_handle]
	mov	cx, [tmp_len]
	mov	dx, [tmp_ptr]
	int	0x21
	jc	.sf_close_fail
	cmp	ax, [tmp_len]
	jne	.sf_close_fail
	call	fix_segs

.sf_after_text:
	mov	ax, [line_count]
	dec	ax
	cmp	[tmp_index], ax
	jae	.sf_next

	mov	ah, 0x40
	mov	bx, [file_handle]
	mov	cx, 2
	mov	dx, crlf
	int	0x21
	jc	.sf_close_fail
	cmp	ax, 2
	jne	.sf_close_fail
	call	fix_segs

.sf_next:
	inc	word [tmp_index]
	jmp	.sf_loop

.sf_close_ok:
	mov	ah, 0x3E
	mov	bx, [file_handle]
	int	0x21
	call	fix_segs
	mov	byte [dirty], 0
	mov	word [status_ptr], msg_saved
	ret

.sf_close_fail:
	push	ax
	mov	ah, 0x3E
	mov	bx, [file_handle]
	int	0x21
	call	fix_segs
	pop	ax

.sf_fail:
	mov	byte [save_failed], 1
	mov	word [status_ptr], msg_save_err
	call	beep
	ret

load_append_char:
	push	ax
	push	bx
	push	si		; Caller's parse loop uses SI for the read buf
	push	di
	mov	[tmp_char], al

	; Use load_col (not get_line_info) as the insert position, because
	; get_line_info skips trailing spaces — a space would write at the
	; current position, but the next call would see the same "length"
	; and overwrite it with a non-space.
	mov	bx, [load_col]
	cmp	bx, COLS
	jae	.lac_done
	mov	ax, [load_line]
	call	get_line_ptr_di
	mov	al, [tmp_char]
	mov	[di + bx], al
	inc	word [load_col]

.lac_done:
	pop	di
	pop	si
	pop	bx
	pop	ax
	ret

load_newline:
	cmp	word [line_count], MAX_LINES
	jae	.ln_done
	inc	word [load_line]
	inc	word [line_count]
	mov	word [load_col], 0
.ln_done:
	ret

; ============================================================================
; Screen
; ============================================================================

redraw_screen:
	call	fix_segs
	call	hide_text_cursor
	xor	bx, bx
.rs_rows:
	cmp	bx, VIEW_ROWS
	jae	.rs_status
	mov	ax, [top_line]
	add	ax, bx
	cmp	ax, [line_count]
	jb	.rs_have_line
	mov	bp, blank_line
	jmp	.rs_draw
.rs_have_line:
	call	get_line_ptr_di
	mov	bp, di
.rs_draw:
	mov	dh, bl
	call	write_editor_line
	inc	bx
	jmp	.rs_rows

.rs_status:
	call	build_status_line
	mov	dh, 24
	mov	bp, render_buf
	call	write_status_line

	mov	ax, [cur_line]
	sub	ax, [top_line]
	mov	dh, al
	mov	ax, [cur_col]
	mov	dl, al
	mov	ah, 0x02
	xor	bh, bh
	int	0x10
	call	show_text_cursor
	ret

refresh_after_move:
	mov	ax, [top_line]
	cmp	ax, [tmp_top]
	jne	.ram_full
	call	refresh_status_cursor
	ret
.ram_full:
	call	redraw_screen
	ret

refresh_status_cursor:
	call	redraw_status_only
	call	position_cursor
	ret

redraw_status_only:
	call	hide_text_cursor
	call	build_status_line
	mov	dh, 24
	mov	bp, render_buf
	call	write_status_line
	ret

redraw_current_line:
	mov	ax, [cur_line]
	jmp	redraw_line_ax

redraw_line_ax:
	push	ax
	push	bx
	push	dx
	push	bp
	call	hide_text_cursor
	cmp	ax, [top_line]
	jb	.rla_done
	mov	dx, ax
	sub	dx, [top_line]
	cmp	dx, VIEW_ROWS
	jae	.rla_done
	cmp	ax, [line_count]
	jb	.rla_have
	mov	bp, blank_line
	jmp	.rla_draw
.rla_have:
	call	get_line_ptr_di
	mov	bp, di
.rla_draw:
	mov	dh, dl
	call	write_editor_line
.rla_done:
	pop	bp
	pop	dx
	pop	bx
	pop	ax
	ret

position_cursor:
	push	ax
	push	dx
	call	hide_text_cursor
	mov	ax, [cur_line]
	sub	ax, [top_line]
	mov	dh, al
	mov	ax, [cur_col]
	mov	dl, al
	mov	ah, 0x02
	xor	bh, bh
	int	0x10
	call	show_text_cursor
	pop	dx
	pop	ax
	ret

paint_last_char:
	push	ax
	push	bx
	push	cx
	push	dx
	call	hide_text_cursor
	mov	ah, 0x02
	xor	bh, bh
	mov	dh, [last_paint_line]
	sub	dh, [top_line]
	mov	dl, [last_paint_col]
	int	0x10
	mov	ah, 0x09
	mov	al, [tmp_char]
	xor	bh, bh
	mov	bl, 0x07
	mov	cx, 1
	int	0x10
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

build_status_line:
	mov	di, render_buf
	mov	cx, COLS
	mov	al, ' '
	cld
	rep	stosb

	mov	di, render_buf
	mov	si, msg_edit
	call	copy_zstr_to_buf
	mov	si, filename
	call	copy_zstr_to_buf
	cmp	byte [dirty], 0
	je	.bs_msg
	mov	al, ' '
	stosb
	mov	al, '*'
	stosb
.bs_msg:
	mov	al, ' '
	stosb
	mov	al, '-'
	stosb
	mov	al, ' '
	stosb
	mov	si, [status_ptr]
	call	copy_zstr_to_buf

	mov	di, render_buf + 48
	mov	si, msg_keys
	call	copy_zstr_to_buf
	ret

copy_zstr_to_buf:
	cmp	di, render_buf + COLS
	jae	.cz_done
.cz_loop:
	lodsb
	or	al, al
	jz	.cz_done
	cmp	di, render_buf + COLS
	jae	.cz_done
	stosb
	jmp	.cz_loop
.cz_done:
	ret

write_editor_line:
	push	ax
	push	bx
	push	cx
	push	dx
	push	bp
	push	es
	push	cs
	pop	es
	mov	ax, 0x1300
	mov	bl, 0x07
	xor	bh, bh
	mov	cx, COLS
	xor	dl, dl
	int	0x10
	pop	es
	pop	bp
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

write_status_line:
	push	ax
	push	bx
	push	cx
	push	dx
	push	bp
	push	es
	push	cs
	pop	es
	mov	ax, 0x1300
	mov	bl, 0x70
	xor	bh, bh
	mov	cx, COLS
	xor	dl, dl
	int	0x10
	pop	es
	pop	bp
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

clear_screen:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	ax, 0x0600
	mov	bh, 0x07
	xor	cx, cx
	mov	dx, 0x184F
	int	0x10
	mov	ah, 0x02
	xor	bh, bh
	xor	dx, dx
	int	0x10
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

hide_text_cursor:
	push	ax
	push	cx
	mov	ah, 0x01
	mov	ch, 0x20
	mov	cl, 0x07
	int	0x10
	pop	cx
	pop	ax
	ret

show_text_cursor:
	push	ax
	push	cx
	mov	ah, 0x01
	mov	ch, 0x06
	mov	cl, 0x07
	int	0x10
	pop	cx
	pop	ax
	ret

; ============================================================================
; Helpers
; ============================================================================

fix_segs:
	push	cs
	pop	ds
	push	cs
	pop	es
	ret

parse_cmdline:
	mov	si, 0x0081
	call	skip_spaces
	cmp	byte [si], 0x0D
	je	.pc_default
	cmp	byte [si], 0
	je	.pc_default
	mov	di, filename
.pc_copy:
	lodsb
	cmp	al, 0x0D
	je	.pc_done
	cmp	al, ' '
	je	.pc_done
	cmp	al, 0
	je	.pc_done
	cmp	di, filename + MAX_NAME
	jae	.pc_done
	stosb
	jmp	.pc_copy
.pc_done:
	mov	byte [di], 0
	ret

.pc_default:
	mov	si, default_name
	mov	di, filename
.pc_def_loop:
	lodsb
	stosb
	or	al, al
	jnz	.pc_def_loop
	ret

skip_spaces:
	cmp	byte [si], ' '
	je	.ss_inc
	cmp	byte [si], 9
	jne	.ss_done
.ss_inc:
	inc	si
	jmp	skip_spaces
.ss_done:
	ret

clear_all_lines:
	mov	di, line_data
	mov	cx, BUF_BYTES
	mov	al, ' '
	cld
	rep	stosb
	mov	word [line_count], 1
	ret

clear_line_index:
	push	ax
	call	get_line_ptr_di
	mov	cx, COLS
	mov	al, ' '
	cld
	rep	stosb
	pop	ax
	ret

get_line_ptr_di:
	push	ax
	push	bx
	push	dx
	mov	bx, ax
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; 16*x
	mov	dx, ax
	mov	ax, bx
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; 64*x
	add	ax, dx			; 80*x
	add	ax, line_data
	mov	di, ax
	pop	dx
	pop	bx
	pop	ax
	ret

get_line_info:
	push	ax
	push	si
	call	get_line_ptr_di
	mov	si, di
	add	si, COLS - 1
	mov	cx, COLS
.gli_scan:
	cmp	byte [si], ' '
	jne	.gli_found
	dec	si
	loop	.gli_scan
	xor	cx, cx
	jmp	.gli_done
.gli_found:
	mov	cx, si
	sub	cx, di
	inc	cx
.gli_done:
	pop	si
	pop	ax
	ret

copy_line_ax_to_dx:
	push	ax
	push	dx
	push	si
	push	di
	push	cx
	call	get_line_ptr_di
	mov	si, di
	mov	ax, dx
	call	get_line_ptr_di
	mov	cx, COLS
	cld
	rep	movsb
	pop	cx
	pop	di
	pop	si
	pop	dx
	pop	ax
	ret

shift_down_from_ax:
	cmp	word [line_count], MAX_LINES
	jae	.sd_fail
	push	ax
	push	bx
	push	dx
	mov	bx, [line_count]
	dec	bx
.sd_loop:
	cmp	bx, ax
	jb	.sd_done
	mov	dx, bx
	inc	dx
	push	ax
	mov	ax, bx
	call	copy_line_ax_to_dx
	pop	ax
	dec	bx
	jmp	.sd_loop
.sd_done:
	call	clear_line_index
	inc	word [line_count]
	pop	dx
	pop	bx
	pop	ax
	clc
	ret
.sd_fail:
	stc
	ret

shift_up_from_ax:
	push	ax
	push	bx
	push	dx
	mov	bx, ax
.su_loop:
	mov	dx, [line_count]
	dec	dx
	cmp	bx, dx
	jae	.su_done
	mov	ax, bx
	inc	ax
	mov	dx, bx
	call	copy_line_ax_to_dx
	inc	bx
	jmp	.su_loop
.su_done:
	mov	ax, [line_count]
	dec	ax
	call	clear_line_index
	dec	word [line_count]
	pop	dx
	pop	bx
	pop	ax
	ret

clamp_cursor:
	mov	ax, [line_count]
	dec	ax
	cmp	[cur_line], ax
	jbe	.cc_line_ok
	mov	[cur_line], ax
.cc_line_ok:
	mov	ax, COLS - 1
	cmp	[cur_col], ax
	jbe	.cc_done
	mov	[cur_col], ax
.cc_done:
	ret

ensure_cursor_visible:
	mov	ax, [cur_line]
	cmp	ax, [top_line]
	jae	.ecv_low_ok
	mov	[top_line], ax
	ret
.ecv_low_ok:
	mov	dx, [top_line]
	add	dx, VIEW_ROWS - 1
	cmp	ax, dx
	jbe	.ecv_done
	sub	ax, VIEW_ROWS - 1
	mov	[top_line], ax
.ecv_done:
	ret

beep:
	push	ax
	push	dx
	mov	dl, 7
	mov	ah, 0x02
	int	0x21
	call	fix_segs
	pop	dx
	pop	ax
	ret

; ============================================================================
; Data
; ============================================================================

msg_edit		db	'EDIT ', 0
msg_help		db	'Editing', 0
msg_loaded		db	'Loaded', 0
msg_new		db	'New file', 0
msg_saved		db	'Saved', 0
msg_save_err	db	'SAVE FAILED', 0
msg_keys		db	'Ctrl-S Save  Esc Exit', 0
default_name		db	'NONAME.TXT', 0
crlf			db	0x0D, 0x0A

filename		times MAX_NAME + 1 db 0
status_ptr		dw	msg_help
file_handle		dw	0
line_count		dw	1
cur_line		dw	0
cur_col			dw	0
top_line		dw	0
dirty			db	0
save_failed		db	0
load_line		dw	0
load_col		dw	0
load_last_cr		db	0
tmp_char		db	0
tmp_index		dw	0
tmp_len			dw	0
tmp_prev_len		dw	0
tmp_next_len		dw	0
tmp_ptr			dw	0
tmp_ptr2		dw	0
tmp_top			dw	0
need_line_redraw	db	0
need_full_redraw	db	0
tried_wrap		db	0
last_paint_line		dw	0
last_paint_col		dw	0

render_buf		times COLS db ' '
blank_line		times COLS db ' '
readbuf			times 512 db 0
line_data		times BUF_BYTES db ' '
