; EDLIN.COM — Line editor for MegaDOS
; Compatible with MS-DOS EDLIN command set
	cpu	8086
	org	0x0100

MAX_LINES	equ	255
MAX_LINE_LEN	equ	253
LINE_SLOT	equ	MAX_LINE_LEN + 1	; 254 bytes per slot

start:
	; Get filename from command tail (PSP:80h)
	mov	si, 0x0081
	call	skip_sp
	cmp	byte [si], 0x0D
	je	no_file
	cmp	byte [si], 0
	je	no_file
	; Copy filename to fname
	mov	di, fname
.copy_fname:
	lodsb
	cmp	al, 0x0D
	je	.fname_done
	cmp	al, ' '
	je	.fname_done
	cmp	al, 0
	je	.fname_done
	mov	[di], al
	inc	di
	jmp	.copy_fname
.fname_done:
	mov	byte [di], 0

	; Try to open file
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	new_file

	; File exists — load it
	mov	[fhandle], ax
	call	load_file
	mov	ah, 0x3E
	mov	bx, [fhandle]
	int	0x21

	; Print file loaded info
	mov	si, msg_end_input
	call	pstr
	jmp	main_loop

new_file:
	mov	word [num_lines], 0
	mov	word [cur_line], 1
	mov	si, msg_new
	call	pstr
	jmp	main_loop

no_file:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

; ============================================================================
; Main command loop
; ============================================================================
main_loop:
	mov	dl, '*'
	mov	ah, 0x02
	int	0x21

	; Read command line
	mov	di, cmdbuf
	call	read_line

	; Parse command
	mov	si, cmdbuf
	call	skip_sp
	cmp	byte [si], 0
	je	main_loop

	; Check for single-letter commands (no number prefix)
	mov	al, [si]
	call	to_upper
	cmp	al, 'Q'
	je	cmd_quit
	cmp	al, 'E'
	je	cmd_save_exit
	cmp	al, 'L'
	je	cmd_list_default
	cmp	al, 'P'
	je	cmd_page_default
	cmp	al, 'I'
	je	cmd_insert_cur

	; T = merge file at current line
	cmp	al, 'T'
	je	cmd_transfer_cur

	; Must start with a number, '.', '#', '+', '-'
	call	parse_lineref	; AX = line number
	jc	cmd_error
	mov	[range_start], ax
	mov	[range_end], ax
	call	skip_sp

	; What follows the number?
	mov	byte [search_ask], 0
	mov	al, [si]
	cmp	al, 0
	je	cmd_edit_line		; Just a number — edit that line
	call	to_upper

	cmp	al, ','
	je	.parse_range
	cmp	al, 'L'
	je	cmd_list_from
	cmp	al, 'D'
	je	cmd_delete_one
	cmp	al, 'I'
	je	cmd_insert_at
	cmp	al, 'P'
	je	cmd_page_from
	cmp	al, 'T'
	je	cmd_transfer_at
	cmp	al, '?'
	je	.set_ask_1
	cmp	al, 'S'
	je	cmd_search_from
	cmp	al, 'R'
	je	cmd_replace_from
	jmp	cmd_error
.set_ask_1:
	mov	byte [search_ask], 1
	inc	si
	mov	al, [si]
	call	to_upper
	cmp	al, 'S'
	je	cmd_search_from
	cmp	al, 'R'
	je	cmd_replace_from
	jmp	cmd_error

.parse_range:
	inc	si		; Skip comma
	call	skip_sp
	; Check for command letter right after comma (means "last" only)
	mov	al, [si]
	call	to_upper
	cmp	al, 'L'
	je	cmd_list_to
	cmp	al, 'D'
	je	cmd_delete_to
	cmp	al, 'P'
	je	cmd_page_to
	cmp	al, '?'
	je	.set_ask_2
	cmp	al, 'S'
	je	cmd_search_to
	cmp	al, 'R'
	je	cmd_replace_to
	jmp	.parse_range_num
.set_ask_2:
	mov	byte [search_ask], 1
	inc	si
	mov	al, [si]
	call	to_upper
	cmp	al, 'S'
	je	cmd_search_to
	cmp	al, 'R'
	je	cmd_replace_to
	jmp	cmd_error
.parse_range_num:
	; Parse second number
	call	parse_lineref
	jc	cmd_error
	mov	[range_end], ax
	call	skip_sp
	mov	al, [si]
	call	to_upper
	cmp	al, 'L'
	je	cmd_list_range
	cmp	al, 'D'
	je	cmd_delete_range
	cmp	al, 'P'
	je	cmd_page_range
	cmp	al, ','
	je	.parse_dest
	cmp	al, '?'
	je	.set_ask_3
	cmp	al, 'S'
	je	cmd_search_range
	cmp	al, 'R'
	je	cmd_replace_range
	jmp	cmd_error
.set_ask_3:
	mov	byte [search_ask], 1
	inc	si
	mov	al, [si]
	call	to_upper
	cmp	al, 'S'
	je	cmd_search_range
	cmp	al, 'R'
	je	cmd_replace_range
	jmp	cmd_error

.parse_dest:
	; Three-arg: first,last,dest[,count]C or first,last,destM
	inc	si
	call	skip_sp
	call	parse_lineref
	jc	cmd_error
	mov	[dest_line], ax
	call	skip_sp
	mov	al, [si]
	call	to_upper
	cmp	al, 'C'
	je	cmd_copy_block
	cmp	al, 'M'
	je	cmd_move_block
	; Check for ,countC
	cmp	al, ','
	jne	cmd_error
	inc	si
	call	skip_sp
	call	parse_num
	mov	[copy_count], ax
	call	skip_sp
	mov	al, [si]
	call	to_upper
	cmp	al, 'C'
	je	cmd_copy_block_n
	jmp	cmd_error

cmd_error:
	mov	si, msg_error
	call	pstr
	jmp	main_loop

; ============================================================================
; LIST command
; ============================================================================
cmd_list_default:
	; L with no args: 23 lines centered on current line
	mov	ax, [cur_line]
	sub	ax, 11
	jnc	.ld_ok
	mov	ax, 1
.ld_ok:
	mov	[range_start], ax
	add	ax, 22
	mov	[range_end], ax
	jmp	do_list

cmd_list_from:
	; nL: 23 lines starting from n
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	add	word [range_end], 22
	jmp	do_list

cmd_list_to:
	; n,L: from cur-11 through range_start
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	mov	ax, [cur_line]
	sub	ax, 11
	jnc	.lt_ok
	mov	ax, 1
.lt_ok:
	mov	[range_start], ax
	jmp	do_list

cmd_list_range:
	; n,mL
	inc	si
do_list:
	; Clamp range
	cmp	word [range_start], 0
	jne	.dl_s_ok
	mov	word [range_start], 1
.dl_s_ok:
	mov	ax, [num_lines]
	cmp	[range_end], ax
	jbe	.dl_e_ok
	mov	[range_end], ax
.dl_e_ok:
	mov	cx, [range_start]
.dl_loop:
	cmp	cx, [range_end]
	ja	.dl_done
	cmp	cx, [num_lines]
	ja	.dl_done
	push	cx
	; Print current-line marker
	cmp	cx, [cur_line]
	jne	.dl_not_cur
	mov	dl, '*'
	jmp	.dl_mark
.dl_not_cur:
	mov	dl, ' '
.dl_mark:
	mov	ah, 0x02
	int	0x21
	; Print line number
	mov	ax, cx
	call	print_dec
	mov	si, msg_colon
	call	pstr
	; Print line content
	pop	cx
	push	cx
	mov	ax, cx
	call	get_line_ptr
	call	pstr
	call	crlf
	pop	cx
	inc	cx
	jmp	.dl_loop
.dl_done:
	jmp	main_loop

; ============================================================================
; PAGE command (like L but updates current line)
; ============================================================================
cmd_page_default:
	mov	ax, [cur_line]
	inc	ax
	mov	[range_start], ax
	add	ax, 22
	mov	[range_end], ax
	jmp	do_page

cmd_page_from:
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	add	word [range_end], 22
	jmp	do_page

cmd_page_to:
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	mov	ax, [cur_line]
	sub	ax, 11
	jnc	.pt_ok
	mov	ax, 1
.pt_ok:
	mov	[range_start], ax
	jmp	do_page

cmd_page_range:
	inc	si
do_page:
	; Same as list but update cur_line
	cmp	word [range_start], 0
	jne	.dp_s_ok
	mov	word [range_start], 1
.dp_s_ok:
	mov	ax, [num_lines]
	cmp	[range_end], ax
	jbe	.dp_e_ok
	mov	[range_end], ax
.dp_e_ok:
	mov	cx, [range_start]
.dp_loop:
	cmp	cx, [range_end]
	ja	.dp_done
	cmp	cx, [num_lines]
	ja	.dp_done
	push	cx
	mov	[cur_line], cx	; P updates current line
	cmp	cx, [cur_line]
	jne	.dp_not_cur
	mov	dl, '*'
	jmp	.dp_mark
.dp_not_cur:
	mov	dl, ' '
.dp_mark:
	mov	ah, 0x02
	int	0x21
	mov	ax, cx
	call	print_dec
	mov	si, msg_colon
	call	pstr
	pop	cx
	push	cx
	mov	ax, cx
	call	get_line_ptr
	call	pstr
	call	crlf
	pop	cx
	inc	cx
	jmp	.dp_loop
.dp_done:
	jmp	main_loop

; ============================================================================
; EDIT LINE command
; ============================================================================
cmd_edit_line:
	mov	ax, [range_start]
	cmp	ax, 0
	je	main_loop
	cmp	ax, [num_lines]
	ja	main_loop
	mov	[cur_line], ax
	; Show current content
	push	ax
	call	print_dec
	mov	si, msg_colon_star
	call	pstr
	pop	ax
	push	ax
	call	get_line_ptr
	call	pstr
	call	crlf
	; Prompt for replacement
	pop	ax
	push	ax
	call	print_dec
	mov	si, msg_colon_star
	call	pstr
	mov	di, linebuf
	call	read_line
	; If empty or Ctrl-C, keep original
	cmp	byte [linebuf], 0
	je	.edit_keep
	cmp	byte [linebuf], 0x03
	je	.edit_keep
	; Replace line
	pop	ax
	call	get_line_ptr
	mov	di, si
	mov	si, linebuf
	mov	cx, MAX_LINE_LEN
.edit_copy:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jz	.edit_done
	dec	cx
	jnz	.edit_copy
	mov	byte [di-1], 0
.edit_done:
	jmp	main_loop
.edit_keep:
	pop	ax
	jmp	main_loop

; ============================================================================
; INSERT command
; ============================================================================
cmd_insert_cur:
	mov	ax, [cur_line]
	jmp	do_insert
cmd_insert_at:
	mov	ax, [range_start]
do_insert:
	mov	[insert_at], ax
.ins_loop:
	mov	ax, [insert_at]
	call	print_dec
	mov	si, msg_colon_star
	call	pstr

	mov	di, linebuf
	call	read_line

	; Ctrl-C exits insert mode
	cmp	byte [linebuf], 0x03
	je	.ins_done

	; Check line limit
	cmp	word [num_lines], MAX_LINES
	jae	.ins_full

	; Shift lines down
	mov	ax, [insert_at]
	call	shift_lines_down

	; Copy linebuf to line slot
	mov	ax, [insert_at]
	call	get_line_ptr
	mov	di, si
	mov	si, linebuf
	mov	cx, MAX_LINE_LEN
.ins_copy:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jz	.ins_copied
	dec	cx
	jnz	.ins_copy
	mov	byte [di-1], 0
.ins_copied:
	inc	word [num_lines]
	inc	word [insert_at]
	jmp	.ins_loop
.ins_full:
	mov	si, msg_full
	call	pstr
.ins_done:
	jmp	main_loop

; ============================================================================
; DELETE command
; ============================================================================
cmd_delete_one:
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	jmp	do_delete

cmd_delete_to:
	; ,nD — delete from current through range_start
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	mov	ax, [cur_line]
	mov	[range_start], ax
	jmp	do_delete

cmd_delete_range:
	inc	si
do_delete:
	mov	ax, [range_start]
	cmp	ax, 0
	je	main_loop
	cmp	ax, [num_lines]
	ja	main_loop
	mov	dx, [range_end]
	cmp	dx, [num_lines]
	jbe	.del_ok
	mov	dx, [num_lines]
	mov	[range_end], dx
.del_ok:
	; Count = end - start + 1
	mov	cx, dx
	sub	cx, ax
	inc	cx
	call	shift_lines_up
	sub	[num_lines], cx
	; Set current line to start of deleted range
	mov	ax, [range_start]
	cmp	ax, [num_lines]
	jbe	.del_cur_ok
	mov	ax, [num_lines]
	or	ax, ax
	jnz	.del_cur_ok
	mov	ax, 1
.del_cur_ok:
	mov	[cur_line], ax
	jmp	main_loop

; ============================================================================
; SEARCH command
; ============================================================================
cmd_search_from:
	; nS — search from n to end
	inc	si
	mov	ax, [num_lines]
	mov	[range_end], ax
	jmp	do_search
cmd_search_to:
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	mov	ax, [cur_line]
	mov	[range_start], ax
	jmp	do_search
cmd_search_range:
	inc	si
do_search:
	; Copy search string from SI
	mov	di, search_str
	call	copy_arg
	; Search lines
	mov	cx, [range_start]
	cmp	cx, 0
	jne	.srch_loop
	mov	cx, 1
.srch_loop:
	cmp	cx, [range_end]
	ja	.srch_not_found
	cmp	cx, [num_lines]
	ja	.srch_not_found
	push	cx
	mov	ax, cx
	call	get_line_ptr	; SI = line text
	mov	di, search_str
	call	str_in_str	; CF=0 if found
	pop	cx
	jnc	.srch_found
	inc	cx
	jmp	.srch_loop
.srch_found:
	; Display the matching line
	push	cx
	mov	dl, '*'
	mov	ah, 0x02
	int	0x21
	mov	ax, cx
	call	print_dec
	mov	si, msg_colon
	call	pstr
	pop	cx
	push	cx
	mov	ax, cx
	call	get_line_ptr
	call	pstr
	call	crlf
	pop	cx
	; If interactive, ask O.K.?
	cmp	byte [search_ask], 0
	je	.srch_accept
	mov	si, msg_ok
	call	pstr
	mov	ah, 0x08
	int	0x21
	call	to_upper
	call	crlf
	cmp	al, 'Y'
	je	.srch_accept
	cmp	al, 0x0D		; Enter = accept
	je	.srch_accept
	; Not accepted — continue searching
	inc	cx
	jmp	.srch_loop
.srch_accept:
	mov	[cur_line], cx
	jmp	main_loop
.srch_not_found:
	mov	si, msg_not_found
	call	pstr
	jmp	main_loop

; ============================================================================
; REPLACE command
; ============================================================================
cmd_replace_from:
	inc	si
	mov	ax, [num_lines]
	mov	[range_end], ax
	jmp	do_replace
cmd_replace_to:
	inc	si
	mov	ax, [range_start]
	mov	[range_end], ax
	mov	ax, [cur_line]
	mov	[range_start], ax
	jmp	do_replace
cmd_replace_range:
	inc	si
do_replace:
	; Parse: search_string^Zreplace_string
	mov	di, search_str
.repl_copy_s:
	lodsb
	cmp	al, 0x1A		; Ctrl-Z separator
	je	.repl_got_sep
	cmp	al, 0
	je	.repl_no_repl
	mov	[di], al
	inc	di
	jmp	.repl_copy_s
.repl_no_repl:
	mov	byte [di], 0
	mov	byte [replace_str], 0	; Delete mode (replace with nothing)
	jmp	.repl_go
.repl_got_sep:
	mov	byte [di], 0
	; Copy replace string
	mov	di, replace_str
	call	copy_arg
.repl_go:
	mov	cx, [range_start]
	cmp	cx, 0
	jne	.repl_loop
	mov	cx, 1
.repl_loop:
	cmp	cx, [range_end]
	ja	.repl_done
	cmp	cx, [num_lines]
	ja	.repl_done
	push	cx
	mov	ax, cx
	call	get_line_ptr	; SI = line text
	mov	di, search_str
	call	str_in_str
	pop	cx
	jc	.repl_next
	; Found — do replacement in this line
	push	cx
	mov	ax, cx
	call	get_line_ptr
	call	do_replace_in_line
	pop	cx
.repl_next:
	inc	cx
	jmp	.repl_loop
.repl_done:
	jmp	main_loop

; Replace search_str with replace_str in line at SI
do_replace_in_line:
	; Simple: rebuild line in linebuf with replacement
	push	si
	mov	di, linebuf
	; Get search string length
	push	si
	mov	si, search_str
	xor	cx, cx
.drl_slen:
	cmp	byte [si], 0
	je	.drl_slen_done
	inc	si
	inc	cx
	jmp	.drl_slen
.drl_slen_done:
	mov	[.drl_search_len], cx
	pop	si		; SI = line text
.drl_scan:
	cmp	byte [si], 0
	je	.drl_end
	; Check if search_str matches at SI
	push	si
	push	di
	mov	di, search_str
	mov	cx, [.drl_search_len]
.drl_cmp:
	cmp	cx, 0
	je	.drl_match
	mov	al, [si]
	cmp	al, [di]
	jne	.drl_no_match
	inc	si
	inc	di
	dec	cx
	jmp	.drl_cmp
.drl_match:
	pop	di
	pop	si
	; Skip search_str length in source
	add	si, [.drl_search_len]
	; Copy replace_str to output
	push	si
	mov	si, replace_str
.drl_copy_repl:
	lodsb
	or	al, al
	jz	.drl_repl_done
	mov	[di], al
	inc	di
	jmp	.drl_copy_repl
.drl_repl_done:
	pop	si
	jmp	.drl_scan	; Continue scanning rest of line
.drl_no_match:
	pop	di
	pop	si
	; Copy one char
	movsb
	jmp	.drl_scan
.drl_end:
	mov	byte [di], 0
	; Copy linebuf back to original line
	pop	di		; DI = original line start (was pushed as SI)
	mov	si, linebuf
	mov	cx, MAX_LINE_LEN
.drl_copy_back:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jz	.drl_back_done
	dec	cx
	jnz	.drl_copy_back
	mov	byte [di-1], 0
.drl_back_done:
	ret
.drl_search_len: dw	0

; ============================================================================
; COPY BLOCK command: first,last,dest[,count]C
; ============================================================================
cmd_copy_block:
	mov	word [copy_count], 1
cmd_copy_block_n:
	; Validate: dest cannot be inside source range
	mov	ax, [dest_line]
	cmp	ax, [range_start]
	jb	.cb_ok
	cmp	ax, [range_end]
	jbe	cmd_error_jmp
.cb_ok:
	mov	cx, [copy_count]
	or	cx, cx
	jz	.cb_done
.cb_repeat:
	push	cx
	; Number of lines to copy
	mov	cx, [range_end]
	sub	cx, [range_start]
	inc	cx		; CX = count of lines
	mov	[cb_count], cx
	; Insert CX blank lines at dest
	mov	ax, [dest_line]
	mov	bx, cx
.cb_make_room:
	cmp	word [num_lines], MAX_LINES
	jae	.cb_full
	push	ax
	push	bx
	call	shift_lines_down
	inc	word [num_lines]
	pop	bx
	pop	ax
	dec	bx
	jnz	.cb_make_room
	; Adjust source range if dest is before it
	mov	ax, [dest_line]
	cmp	ax, [range_start]
	ja	.cb_no_adjust
	mov	cx, [cb_count]
	add	[range_start], cx
	add	[range_end], cx
.cb_no_adjust:
	; Copy lines from source to dest
	mov	cx, [cb_count]
	mov	ax, [range_start]
	mov	bx, [dest_line]
.cb_copy_loop:
	push	cx
	push	ax
	push	bx
	; Read source line
	call	get_line_ptr	; SI = source
	mov	di, linebuf
	push	di
	mov	cx, LINE_SLOT
	rep	movsb
	; Write to dest line
	pop	si		; SI = linebuf
	pop	bx
	pop	ax
	push	ax
	push	bx
	xchg	ax, bx
	call	get_line_ptr	; SI = dest slot
	mov	di, si
	mov	si, linebuf
	mov	cx, LINE_SLOT
	rep	movsb
	pop	bx
	pop	ax
	pop	cx
	inc	ax
	inc	bx
	dec	cx
	jnz	.cb_copy_loop
	; Set current line to first copied line at dest
	mov	ax, [dest_line]
	mov	[cur_line], ax
	pop	cx		; repeat counter
	dec	cx
	jnz	.cb_repeat
.cb_done:
	jmp	main_loop
.cb_full:
	pop	cx		; clean up repeat counter
	mov	si, msg_full
	call	pstr
	jmp	main_loop
cmd_error_jmp:
	jmp	cmd_error
cb_count:	dw	0

; ============================================================================
; MOVE BLOCK command: first,last,destM
; ============================================================================
cmd_move_block:
	; Validate: dest cannot be inside source range
	mov	ax, [dest_line]
	cmp	ax, [range_start]
	jb	.mb_ok
	cmp	ax, [range_end]
	jbe	cmd_error_jmp2
.mb_ok:
	; Copy first, then delete originals
	; Save original range
	mov	ax, [range_start]
	mov	[mb_orig_start], ax
	mov	ax, [range_end]
	mov	[mb_orig_end], ax

	; Do copy (count=1)
	mov	word [copy_count], 1
	call	cmd_copy_block_inline

	; Now delete the original lines
	; Adjust original range if dest was before it
	mov	ax, [dest_line]
	cmp	ax, [mb_orig_start]
	ja	.mb_no_adj
	mov	cx, [mb_orig_end]
	sub	cx, [mb_orig_start]
	inc	cx
	add	[mb_orig_start], cx
	add	[mb_orig_end], cx
.mb_no_adj:
	mov	ax, [mb_orig_start]
	mov	[range_start], ax
	mov	ax, [mb_orig_end]
	mov	[range_end], ax
	; Delete
	mov	dx, [range_end]
	mov	cx, dx
	sub	cx, [range_start]
	inc	cx
	call	shift_lines_up
	sub	[num_lines], cx
	jmp	main_loop
cmd_error_jmp2:
	jmp	cmd_error
mb_orig_start:	dw	0
mb_orig_end:	dw	0

; Inline copy helper (doesn't jump to main_loop)
cmd_copy_block_inline:
	mov	cx, [range_end]
	sub	cx, [range_start]
	inc	cx
	mov	[cbi_count], cx
	; Make room at dest
	mov	ax, [dest_line]
	mov	bx, cx
.cbi_room:
	cmp	word [num_lines], MAX_LINES
	jae	.cbi_ret
	push	ax
	push	bx
	call	shift_lines_down
	inc	word [num_lines]
	pop	bx
	pop	ax
	dec	bx
	jnz	.cbi_room
	; Adjust source if dest before it
	mov	ax, [dest_line]
	cmp	ax, [range_start]
	ja	.cbi_no_adj
	mov	cx, [cbi_count]
	add	[range_start], cx
	add	[range_end], cx
.cbi_no_adj:
	; Copy
	mov	cx, [cbi_count]
	mov	ax, [range_start]
	mov	bx, [dest_line]
.cbi_loop:
	push	cx
	push	ax
	push	bx
	call	get_line_ptr
	mov	di, linebuf
	push	di
	mov	cx, LINE_SLOT
	rep	movsb
	pop	si
	pop	bx
	pop	ax
	push	ax
	push	bx
	xchg	ax, bx
	call	get_line_ptr
	mov	di, si
	mov	si, linebuf
	mov	cx, LINE_SLOT
	rep	movsb
	pop	bx
	pop	ax
	pop	cx
	inc	ax
	inc	bx
	dec	cx
	jnz	.cbi_loop
	mov	ax, [dest_line]
	mov	[cur_line], ax
.cbi_ret:
	ret
cbi_count:	dw	0

; ============================================================================
; TRANSFER (MERGE) command: [dest]Tfilename
; ============================================================================
cmd_transfer_cur:
	mov	ax, [cur_line]
	mov	[dest_line], ax
	inc	si		; Skip 'T'
	jmp	do_transfer
cmd_transfer_at:
	mov	ax, [range_start]
	mov	[dest_line], ax
	inc	si		; Skip 'T'
do_transfer:
	; SI = filename (immediately after T, no space skip)
	cmp	byte [si], 0
	je	.tf_err
	; Open the file
	mov	dx, si		; DS:DX = filename
	mov	ah, 0x3D
	mov	al, 0
	int	0x21
	jc	.tf_not_found
	mov	[tf_handle], ax
	; Read lines and insert at dest
	mov	ax, [dest_line]
	mov	[tf_insert], ax
.tf_loop:
	cmp	word [num_lines], MAX_LINES
	jae	.tf_full
	; Read a line
	mov	di, linebuf
	mov	cx, MAX_LINE_LEN
.tf_read_char:
	push	cx
	mov	ah, 0x3F
	mov	bx, [tf_handle]
	mov	cx, 1
	mov	dx, charbuf
	int	0x21
	pop	cx
	cmp	ax, 0
	je	.tf_eof
	mov	al, [charbuf]
	cmp	al, 0x0D
	je	.tf_cr
	cmp	al, 0x0A
	je	.tf_line_done
	cmp	al, 0x1A
	je	.tf_eof
	mov	[di], al
	inc	di
	dec	cx
	jnz	.tf_read_char
.tf_cr:
	; Skip LF
	push	cx
	mov	ah, 0x3F
	mov	bx, [tf_handle]
	mov	cx, 1
	mov	dx, charbuf
	int	0x21
	pop	cx
.tf_line_done:
	mov	byte [di], 0
	; Insert this line
	mov	ax, [tf_insert]
	call	shift_lines_down
	mov	ax, [tf_insert]
	call	get_line_ptr
	mov	di, si
	mov	si, linebuf
	mov	cx, MAX_LINE_LEN
.tf_copy:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jz	.tf_stored
	dec	cx
	jnz	.tf_copy
	mov	byte [di-1], 0
.tf_stored:
	inc	word [num_lines]
	inc	word [tf_insert]
	jmp	.tf_loop
.tf_eof:
	; If partial line in buffer, store it
	cmp	di, linebuf
	je	.tf_close
	mov	byte [di], 0
	mov	ax, [tf_insert]
	call	shift_lines_down
	mov	ax, [tf_insert]
	call	get_line_ptr
	mov	di, si
	mov	si, linebuf
.tf_eof_copy:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jnz	.tf_eof_copy
	inc	word [num_lines]
.tf_close:
	mov	ah, 0x3E
	mov	bx, [tf_handle]
	int	0x21
	; Set current line to first inserted
	mov	ax, [dest_line]
	mov	[cur_line], ax
	jmp	main_loop
.tf_not_found:
	mov	si, msg_fnf
	call	pstr
	jmp	main_loop
.tf_full:
	mov	si, msg_tf_full
	call	pstr
	jmp	.tf_close
.tf_err:
	jmp	cmd_error
tf_handle:	dw	0
tf_insert:	dw	0

; ============================================================================
; QUIT command
; ============================================================================
cmd_quit:
	mov	si, msg_abort
	call	pstr
	mov	ah, 0x08
	int	0x21
	call	to_upper
	cmp	al, 'Y'
	je	.quit_yes
	call	crlf
	jmp	main_loop
.quit_yes:
	call	crlf
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; SAVE AND EXIT
; ============================================================================
cmd_save_exit:
	call	save_file
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; File I/O
; ============================================================================
load_file:
	mov	word [num_lines], 0
	mov	word [cur_line], 1
.load_loop:
	cmp	word [num_lines], MAX_LINES
	jae	.load_done
	mov	di, linebuf
	mov	cx, MAX_LINE_LEN
.load_char:
	push	cx
	mov	ah, 0x3F
	mov	bx, [fhandle]
	mov	cx, 1
	mov	dx, charbuf
	int	0x21
	pop	cx
	cmp	ax, 0
	je	.load_eof
	mov	al, [charbuf]
	cmp	al, 0x0D
	je	.load_cr
	cmp	al, 0x0A
	je	.load_line_done
	cmp	al, 0x1A
	je	.load_eof
	mov	[di], al
	inc	di
	dec	cx
	jnz	.load_char
.load_cr:
	; Skip LF after CR
	push	cx
	mov	ah, 0x3F
	mov	bx, [fhandle]
	mov	cx, 1
	mov	dx, charbuf
	int	0x21
	pop	cx
.load_line_done:
	mov	byte [di], 0
	inc	word [num_lines]
	mov	ax, [num_lines]
	call	get_line_ptr
	push	di
	mov	di, si
	mov	si, linebuf
.load_store:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jnz	.load_store
	pop	di
	jmp	.load_loop
.load_eof:
	cmp	di, linebuf
	je	.load_done
	mov	byte [di], 0
	inc	word [num_lines]
	mov	ax, [num_lines]
	call	get_line_ptr
	push	di
	mov	di, si
	mov	si, linebuf
.load_store_eof:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jnz	.load_store_eof
	pop	di
.load_done:
	ret

save_file:
	; Rename original to .BAK (best effort)
	; Build .BAK filename
	mov	si, fname
	mov	di, bakname
.bak_copy:
	lodsb
	cmp	al, '.'
	je	.bak_dot
	cmp	al, 0
	je	.bak_no_dot
	mov	[di], al
	inc	di
	jmp	.bak_copy
.bak_no_dot:
.bak_dot:
	mov	byte [di], '.'
	mov	byte [di+1], 'B'
	mov	byte [di+2], 'A'
	mov	byte [di+3], 'K'
	mov	byte [di+4], 0
	; Delete old .BAK if exists
	mov	ah, 0x41
	mov	dx, bakname
	int	0x21		; Ignore errors
	; Rename current file to .BAK
	mov	ah, 0x56
	mov	dx, fname
	mov	di, bakname
	int	0x21		; Ignore errors

	; Create new file
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fname
	int	0x21
	jc	.save_err
	mov	[fhandle], ax

	; Write each line
	mov	cx, 1
.save_loop:
	cmp	cx, [num_lines]
	ja	.save_close
	push	cx
	mov	ax, cx
	call	get_line_ptr
	; Find length
	push	si
	xor	cx, cx
.save_len:
	lodsb
	or	al, al
	jz	.save_got_len
	inc	cx
	jmp	.save_len
.save_got_len:
	pop	dx		; DX = line start
	mov	ah, 0x40
	mov	bx, [fhandle]
	int	0x21
	; Write CR/LF
	mov	ah, 0x40
	mov	bx, [fhandle]
	mov	cx, 2
	mov	dx, crlf_bytes
	int	0x21
	pop	cx
	inc	cx
	jmp	.save_loop
.save_close:
	mov	ah, 0x3E
	mov	bx, [fhandle]
	int	0x21
	ret
.save_err:
	mov	si, msg_save_err
	call	pstr
	ret

; ============================================================================
; Helpers
; ============================================================================

; get_line_ptr: AX = 1-based line number → SI = pointer to line data
get_line_ptr:
	push	ax
	push	dx
	dec	ax
	mov	dx, LINE_SLOT
	mul	dx
	add	ax, line_data
	mov	si, ax
	pop	dx
	pop	ax
	ret

; shift_lines_down: make room at line AX by shifting AX..end down by 1
shift_lines_down:
	push	ax
	push	bx
	push	cx
	push	si
	push	di
	mov	bx, [num_lines]
.sd_loop:
	cmp	bx, ax
	jb	.sd_done
	push	ax
	mov	ax, bx
	call	get_line_ptr
	mov	di, si
	add	di, LINE_SLOT
	mov	cx, LINE_SLOT
	rep	movsb
	pop	ax
	dec	bx
	jmp	.sd_loop
.sd_done:
	pop	di
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; shift_lines_up: remove range_start..range_end, shift rest up
shift_lines_up:
	push	ax
	push	bx
	push	cx
	push	si
	push	di
	mov	ax, [range_start]
	mov	bx, [range_end]
	inc	bx
.su_loop:
	cmp	bx, [num_lines]
	ja	.su_done
	push	ax
	push	bx
	mov	ax, bx
	call	get_line_ptr
	push	si
	pop	di		; Save source as DI... no
	; Need: source = line BX, dest = line AX
	pop	bx
	pop	ax
	push	ax
	push	bx
	push	bx
	mov	ax, bx
	call	get_line_ptr	; SI = source (line BX)
	pop	bx
	pop	bx
	pop	ax
	push	ax
	push	bx
	push	si		; Save source
	call	get_line_ptr	; SI = dest (line AX) — wrong, need DI
	mov	di, si
	pop	si		; SI = source
	mov	cx, LINE_SLOT
	rep	movsb
	pop	bx
	pop	ax
	inc	ax
	inc	bx
	jmp	.su_loop
.su_done:
	pop	di
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; parse_lineref: parse line reference (number, '.', '#', +n, -n)
; Returns AX = line number, CF=0 success / CF=1 error
parse_lineref:
	cmp	byte [si], '.'
	je	.plr_dot
	cmp	byte [si], '#'
	je	.plr_hash
	cmp	byte [si], '+'
	je	.plr_plus
	cmp	byte [si], '-'
	je	.plr_minus
	; Must be a digit
	cmp	byte [si], '0'
	jb	.plr_err
	cmp	byte [si], '9'
	ja	.plr_err
	call	parse_num
	clc
	ret
.plr_dot:
	inc	si
	mov	ax, [cur_line]
	clc
	ret
.plr_hash:
	inc	si
	mov	ax, [num_lines]
	inc	ax
	clc
	ret
.plr_plus:
	inc	si
	call	parse_num
	add	ax, [cur_line]
	clc
	ret
.plr_minus:
	inc	si
	call	parse_num
	push	bx
	mov	bx, [cur_line]
	sub	bx, ax
	mov	ax, bx
	pop	bx
	jnc	.plr_minus_ok
	mov	ax, 1
.plr_minus_ok:
	clc
	ret
.plr_err:
	stc
	ret

; parse_num: parse decimal from SI → AX
parse_num:
	xor	ax, ax
	xor	bx, bx
.pn_loop:
	mov	bl, [si]
	cmp	bl, '0'
	jb	.pn_done
	cmp	bl, '9'
	ja	.pn_done
	sub	bl, '0'
	push	bx
	mov	bx, 10
	mul	bx
	pop	bx
	add	ax, bx
	inc	si
	jmp	.pn_loop
.pn_done:
	ret

; print_dec: print AX as right-justified 3-digit number
print_dec:
	push	ax
	push	cx
	push	dx
	push	bx
	xor	cx, cx
	mov	bx, 10
.pd_div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_div
	; Pad to 3 digits
	mov	bx, 3
	sub	bx, cx
	jbe	.pd_print
.pd_pad:
	push	cx
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	cx
	dec	bx
	jnz	.pd_pad
.pd_print:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pd_print
	pop	bx
	pop	dx
	pop	cx
	pop	ax
	ret

; to_upper: uppercase AL
to_upper:
	cmp	al, 'a'
	jb	.tu_done
	cmp	al, 'z'
	ja	.tu_done
	sub	al, 0x20
.tu_done:
	ret

; skip_sp: skip spaces at SI
skip_sp:
	cmp	byte [si], ' '
	jne	.ss_done
	inc	si
	jmp	skip_sp
.ss_done:
	ret

; copy_arg: copy rest of SI to DI until null
copy_arg:
	lodsb
	mov	[di], al
	inc	di
	or	al, al
	jnz	copy_arg
	ret

; str_in_str: check if null-terminated string at DI exists in string at SI
; Returns CF=0 if found, CF=1 if not
str_in_str:
	push	si
	push	di
.sis_scan:
	cmp	byte [si], 0
	je	.sis_fail
	push	si
	push	di
.sis_cmp:
	cmp	byte [di], 0
	je	.sis_match	; End of search string = found
	mov	al, [si]
	cmp	al, 0
	je	.sis_cmp_fail
	cmp	al, [di]
	jne	.sis_cmp_fail
	inc	si
	inc	di
	jmp	.sis_cmp
.sis_match:
	pop	di
	pop	si
	pop	di
	pop	si
	clc
	ret
.sis_cmp_fail:
	pop	di
	pop	si
	inc	si
	jmp	.sis_scan
.sis_fail:
	pop	di
	pop	si
	stc
	ret

; pstr: print null-terminated string at SI
pstr:
	lodsb
	or	al, al
	jz	.ps_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	pstr
.ps_done:
	ret

; crlf: print CR/LF
crlf:
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	ret

; read_line: read line into DI, handle backspace, Ctrl-C echoes ^C
read_line:
	push	cx
	xor	cx, cx
.rl_loop:
	mov	ah, 0x08
	int	0x21
	cmp	al, 0x03		; Ctrl-C
	je	.rl_ctrlc
	cmp	al, 0x0D		; Enter
	je	.rl_done
	cmp	al, 0x08		; Backspace
	je	.rl_bs
	cmp	cx, MAX_LINE_LEN - 1
	jae	.rl_loop
	mov	[di], al
	inc	di
	inc	cx
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.rl_loop
.rl_bs:
	cmp	cx, 0
	je	.rl_loop
	dec	di
	dec	cx
	mov	dl, 0x08
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x08
	mov	ah, 0x02
	int	0x21
	jmp	.rl_loop
.rl_ctrlc:
	mov	byte [di], 0x03
	inc	di
	; Echo ^C
	mov	dl, '^'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'C'
	mov	ah, 0x02
	int	0x21
.rl_done:
	mov	byte [di], 0
	call	crlf
	pop	cx
	ret

; ============================================================================
; Data
; ============================================================================
msg_usage	db	'File name must be specified', 0x0D, 0x0A, 0
msg_new		db	'New file', 0x0D, 0x0A, 0
msg_end_input	db	'End of input file', 0x0D, 0x0A, 0
msg_error	db	'Entry error', 0x0D, 0x0A, 0
msg_abort	db	'Abort edit (Y/N)? ', 0
msg_save_err	db	'Error saving file', 0x0D, 0x0A, 0
msg_full	db	'Insufficient memory', 0x0D, 0x0A, 0
msg_not_found	db	'Not found', 0x0D, 0x0A, 0
msg_ok		db	'O.K.? ', 0
msg_fnf		db	'File not found', 0x0D, 0x0A, 0
msg_tf_full	db	'Not enough room to merge the entire file', 0x0D, 0x0A, 0
msg_colon	db	': ', 0
msg_colon_star	db	':*', 0
crlf_bytes	db	0x0D, 0x0A

fname		times 78 db 0
bakname		times 78 db 0
fhandle		dw	0
cmdbuf		times 128 db 0
linebuf		times 256 db 0
charbuf		db	0
search_str	times 128 db 0
replace_str	times 128 db 0
num_lines	dw	0
cur_line	dw	1
range_start	dw	0
range_end	dw	0
dest_line	dw	0
insert_at	dw	0
search_ask	db	0
copy_count	dw	1

; Line data: MAX_LINES * LINE_SLOT bytes
line_data:
