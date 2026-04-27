; ANSITEST.COM — exercise ANSI.SYS escape sequences one at a time.
; Each test clears the screen, prints a description, runs the sequence,
; and waits for a keypress before moving on.

	cpu	8086
	org	0x0100

ESC	equ	0x1B

start:
	push	cs
	pop	ds

	call	test_01_cursor_pos
	call	test_02_cursor_up
	call	test_03_cursor_down
	call	test_04_cursor_right
	call	test_05_cursor_left
	call	test_06_clear_screen
	call	test_07_clear_line
	call	test_08_save_restore
	call	test_09_sgr_reset
	call	test_10_sgr_bold
	call	test_11_sgr_fg_colors
	call	test_12_sgr_bg_colors
	call	test_13_combined_attr
	call	test_14_dsr_cursor_pos
	call	test_15_box_drawing
	call	test_16_status_line

	; Reset and exit
	mov	dx, msg_done
	call	puts
	call	wait_key
	call	clear_screen
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; Test 01: Cursor positioning  ESC[r;cH
; ============================================================================
test_01_cursor_pos:
	call	clear_screen
	mov	dx, t01_desc
	call	puts
	call	wait_key
	call	clear_screen
	; Park cursor at row 5 col 10, write 'X'
	mov	dx, t01_seq
	call	puts
	; Park at row 12, col 40, write 'O'
	mov	dx, t01_seq2
	call	puts
	mov	dx, t01_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 02: Cursor up  ESC[nA
; ============================================================================
test_02_cursor_up:
	call	clear_screen
	mov	dx, t02_desc
	call	puts
	call	wait_key
	call	clear_screen
	; Move to row 20 col 10, write '*', then cursor-up 5, write '#'
	mov	dx, t02_seq
	call	puts
	mov	dx, t02_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 03: Cursor down  ESC[nB
; ============================================================================
test_03_cursor_down:
	call	clear_screen
	mov	dx, t03_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t03_seq
	call	puts
	mov	dx, t03_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 04: Cursor right  ESC[nC
; ============================================================================
test_04_cursor_right:
	call	clear_screen
	mov	dx, t04_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t04_seq
	call	puts
	mov	dx, t04_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 05: Cursor left  ESC[nD
; ============================================================================
test_05_cursor_left:
	call	clear_screen
	mov	dx, t05_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t05_seq
	call	puts
	mov	dx, t05_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 06: Clear screen  ESC[2J
; ============================================================================
test_06_clear_screen:
	call	clear_screen
	mov	dx, t06_desc
	call	puts
	call	wait_key
	; Fill screen with junk first
	mov	dx, t06_fill
	call	puts
	call	wait_key
	; Now ESC[2J should wipe it
	mov	dx, t06_seq
	call	puts
	mov	dx, t06_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 07: Clear line  ESC[K
; ============================================================================
test_07_clear_line:
	call	clear_screen
	mov	dx, t07_desc
	call	puts
	call	wait_key
	call	clear_screen
	; Print full line of '#', cursor to mid, ESC[K
	mov	dx, t07_seq
	call	puts
	mov	dx, t07_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 08: Save/restore cursor  ESC[s ESC[u
; ============================================================================
test_08_save_restore:
	call	clear_screen
	mov	dx, t08_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t08_seq
	call	puts
	mov	dx, t08_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 09: SGR reset  ESC[0m
; ============================================================================
test_09_sgr_reset:
	call	clear_screen
	mov	dx, t09_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t09_seq
	call	puts
	mov	dx, t09_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 10: SGR bold  ESC[1m
; ============================================================================
test_10_sgr_bold:
	call	clear_screen
	mov	dx, t10_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t10_seq
	call	puts
	mov	dx, t10_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 11: SGR foreground colors  ESC[30..37m
; ============================================================================
test_11_sgr_fg_colors:
	call	clear_screen
	mov	dx, t11_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t11_seq
	call	puts
	mov	dx, t11_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 12: SGR background colors  ESC[40..47m
; ============================================================================
test_12_sgr_bg_colors:
	call	clear_screen
	mov	dx, t12_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t12_seq
	call	puts
	mov	dx, t12_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 13: Combined attributes (reverse, bold, color)
; ============================================================================
test_13_combined_attr:
	call	clear_screen
	mov	dx, t13_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t13_seq
	call	puts
	mov	dx, t13_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 14: DSR cursor position  ESC[6n
; ============================================================================
; Parks cursor at row 10 col 20, then sends ESC[6n. ANSI.SYS should
; respond with ESC[10;20R via the input stream — we read it back and
; print what we got.
test_14_dsr_cursor_pos:
	call	clear_screen
	mov	dx, t14_desc
	call	puts
	call	wait_key
	call	clear_screen
	; Park cursor at known location (row 10, col 20)
	mov	dx, t14_park
	call	puts
	; Send DSR query
	mov	dx, t14_query
	call	puts
	; Read response bytes (up to 16) and stash them
	mov	cx, 16
	mov	di, t14_response
.t14_read:
	mov	ah, 0x07		; raw input, no echo, no Ctrl-C check
	int	0x21
	or	al, al
	jz	.t14_read_done		; treat NUL as end (extended-key sentinel)
	mov	[di], al
	inc	di
	cmp	al, 'R'			; ANSI DSR response ends with 'R'
	je	.t14_read_done
	dec	cx
	jnz	.t14_read
.t14_read_done:
	mov	byte [di], '$'
	; Move cursor to a clean spot and print what we got
	mov	dx, t14_show
	call	puts
	mov	dx, t14_response
	call	puts_visible
	mov	dx, t14_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 15: Box drawing using cursor positioning
; ============================================================================
test_15_box_drawing:
	call	clear_screen
	mov	dx, t15_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t15_seq
	call	puts
	mov	dx, t15_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Test 16: Status line at bottom (Zork-style)
; ============================================================================
test_16_status_line:
	call	clear_screen
	mov	dx, t16_desc
	call	puts
	call	wait_key
	call	clear_screen
	mov	dx, t16_seq
	call	puts
	mov	dx, t16_caption
	call	puts2_at_25
	call	wait_key
	ret

; ============================================================================
; Helpers
; ============================================================================
puts:
	mov	ah, 0x09
	int	0x21
	ret

; Print response bytes as ESC^[<rest> so escape becomes visible '^['
puts_visible:
	mov	si, dx
.pv_loop:
	lodsb
	cmp	al, '$'
	je	.pv_done
	cmp	al, ESC
	jne	.pv_norm
	mov	dl, '^'
	mov	ah, 0x02
	int	0x21
	mov	dl, '['
	mov	ah, 0x02
	int	0x21
	jmp	.pv_loop
.pv_norm:
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.pv_loop
.pv_done:
	ret

; Park cursor at row 25 col 1, then print string in DX (used for caption)
puts2_at_25:
	push	dx
	mov	dx, esc_park_25
	mov	ah, 0x09
	int	0x21
	pop	dx
	mov	ah, 0x09
	int	0x21
	ret

clear_screen:
	mov	dx, esc_cls
	mov	ah, 0x09
	int	0x21
	ret

wait_key:
	mov	ah, 0x07
	int	0x21
	ret

; ============================================================================
; Strings — all $-terminated
; ============================================================================

esc_cls		db	ESC, '[2J', ESC, '[H$'
esc_park_25	db	ESC, '[25;1H'
		db	'-- press a key --$'

msg_done	db	ESC, '[2J', ESC, '[H'
		db	'All ANSI tests done. Press any key to exit.', 13, 10, '$'

; --- Test 01 ---
t01_desc	db	'Test 01: Cursor positioning ESC[r;cH', 13, 10, 13, 10
		db	'Will move to row 5 col 10 (X) and row 12 col 40 (O).', 13, 10
		db	'Press a key to run the test.$'
t01_seq		db	ESC, '[5;10H', 'X$'
t01_seq2	db	ESC, '[12;40H', 'O$'
t01_caption	db	'X should be row 5 col 10, O at row 12 col 40$'

; --- Test 02 ---
t02_desc	db	'Test 02: Cursor up ESC[nA', 13, 10, 13, 10
		db	'Will write * at row 20 col 10, move up 5, write #.', 13, 10
		db	'Press a key.$'
t02_seq		db	ESC, '[20;10H', '*', ESC, '[5A', '#$'
t02_caption	db	'# should be 5 rows above the * (row 15 area)$'

; --- Test 03 ---
t03_desc	db	'Test 03: Cursor down ESC[nB', 13, 10, 13, 10
		db	'Will write @ at row 5 col 10, move down 8, write &.', 13, 10
		db	'Press a key.$'
t03_seq		db	ESC, '[5;10H', '@', ESC, '[8B', '&$'
t03_caption	db	'& should be 8 rows below the @ (row 13 area)$'

; --- Test 04 ---
t04_desc	db	'Test 04: Cursor right ESC[nC', 13, 10, 13, 10
		db	'Will write [ at row 10 col 5, move right 20, write ].', 13, 10
		db	'Press a key.$'
t04_seq		db	ESC, '[10;5H', '[', ESC, '[20C', ']$'
t04_caption	db	'] should be 20 cols right of the [ (col 25 area)$'

; --- Test 05 ---
t05_desc	db	'Test 05: Cursor left ESC[nD', 13, 10, 13, 10
		db	'Will write > at row 10 col 30, move left 15, write <.', 13, 10
		db	'Press a key.$'
t05_seq		db	ESC, '[10;30H', '>', ESC, '[15D', '<$'
t05_caption	db	'< should be 15 cols left of > (around col 16)$'

; --- Test 06 ---
t06_desc	db	'Test 06: Clear screen ESC[2J', 13, 10, 13, 10
		db	'Will fill screen with text, press key, then clear it.$'
t06_fill	db	'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
		db	'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
		db	'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC$'
t06_seq		db	ESC, '[2J', ESC, '[H$'
t06_caption	db	'Screen should now be empty (just this caption)$'

; --- Test 07 ---
t07_desc	db	'Test 07: Clear line to end ESC[K', 13, 10, 13, 10
		db	'Will write 80 chars on row 10, park at col 20, run ESC[K.$'
t07_seq		db	ESC, '[10;1H', '################################################################################'
		db	ESC, '[10;20H', ESC, '[K$'
t07_caption	db	'Row 10 should have # only in cols 1-19, rest blank$'

; --- Test 08 ---
t08_desc	db	'Test 08: Save and restore cursor ESC[s / ESC[u', 13, 10, 13, 10
		db	'Save at row 5 col 5, move to row 20 col 70, restore, print Y.$'
t08_seq		db	ESC, '[5;5H', ESC, '[s', ESC, '[20;70H', 'X', ESC, '[u', 'Y$'
t08_caption	db	'X should be at row 20 col 70, Y back at row 5 col 5$'

; --- Test 09 ---
t09_desc	db	'Test 09: SGR reset ESC[0m', 13, 10, 13, 10
		db	'Sets reverse video, prints A, resets, prints B.$'
t09_seq		db	ESC, '[5;10H', ESC, '[7m', 'AAAA', ESC, '[0m', 'BBBB$'
t09_caption	db	'AAAA should be reverse video, BBBB normal$'

; --- Test 10 ---
t10_desc	db	'Test 10: SGR bold ESC[1m', 13, 10, 13, 10
		db	'Prints normal, then bold, then reset.$'
t10_seq		db	ESC, '[5;5H', 'normal ', ESC, '[1m', 'BOLD ', ESC, '[0m', 'normal$'
t10_caption	db	'Middle word should be brighter/bolder if supported$'

; --- Test 11 ---
t11_desc	db	'Test 11: SGR foreground colors ESC[30..37m', 13, 10, 13, 10
		db	'Prints letters in 8 colors.$'
t11_seq		db	ESC, '[5;5H'
		db	ESC, '[30m', 'BLACK ', ESC, '[31m', 'RED ', ESC, '[32m', 'GREEN '
		db	ESC, '[33m', 'YELLOW ', ESC, '[34m', 'BLUE ', ESC, '[35m', 'MAGENTA '
		db	ESC, '[36m', 'CYAN ', ESC, '[37m', 'WHITE', ESC, '[0m$'
t11_caption	db	'Each word should be in the named color (mono shows shades)$'

; --- Test 12 ---
t12_desc	db	'Test 12: SGR background colors ESC[40..47m', 13, 10, 13, 10
		db	'Prints letters with 8 background colors.$'
t12_seq		db	ESC, '[5;5H'
		db	ESC, '[40m', ' BK ', ESC, '[41m', ' RD ', ESC, '[42m', ' GN '
		db	ESC, '[43m', ' YL ', ESC, '[44m', ' BL ', ESC, '[45m', ' MG '
		db	ESC, '[46m', ' CY ', ESC, '[47m', ' WH ', ESC, '[0m$'
t12_caption	db	'Each pair of letters should have the named bg color$'

; --- Test 13 ---
t13_desc	db	'Test 13: Combined attributes', 13, 10, 13, 10
		db	'Reverse video + bold + colors stacked.$'
t13_seq		db	ESC, '[5;5H', ESC, '[1;7;33m', 'BOLD-REV-YELLOW', ESC, '[0m'
		db	ESC, '[7;5H', ESC, '[31;47m', 'RED-on-WHITE', ESC, '[0m$'
t13_caption	db	'Both lines should show their stated attributes$'

; --- Test 14 ---
t14_desc	db	'Test 14: DSR cursor position ESC[6n', 13, 10, 13, 10
		db	'Parks cursor at row 10 col 20, sends ESC[6n,', 13, 10
		db	'reads response from input stream, prints it back.', 13, 10
		db	'Expected response: ESC[10;20R$'
t14_park	db	ESC, '[10;20H$'
t14_query	db	ESC, '[6n$'
t14_show	db	ESC, '[15;1H', 'Got back: $'
t14_response	times 24 db 0
t14_caption	db	'Should read: ^[10;20R (^[ is the visible ESC)$'

; --- Test 15 ---
t15_desc	db	'Test 15: Box drawing with cursor positioning', 13, 10, 13, 10
		db	'Draw a 20x10 box using corners and edges.$'
t15_seq:
	; Top edge row 5
	db	ESC, '[5;10H', '+--------------------+'
	; Bottom edge row 14
	db	ESC, '[14;10H', '+--------------------+'
	; Left edges
	db	ESC, '[6;10H', '|'
	db	ESC, '[7;10H', '|'
	db	ESC, '[8;10H', '|'
	db	ESC, '[9;10H', '|'
	db	ESC, '[10;10H', '|'
	db	ESC, '[11;10H', '|'
	db	ESC, '[12;10H', '|'
	db	ESC, '[13;10H', '|'
	; Right edges
	db	ESC, '[6;31H', '|'
	db	ESC, '[7;31H', '|'
	db	ESC, '[8;31H', '|'
	db	ESC, '[9;31H', '|'
	db	ESC, '[10;31H', '|'
	db	ESC, '[11;31H', '|'
	db	ESC, '[12;31H', '|'
	db	ESC, '[13;31H', '|'
	; Centered text
	db	ESC, '[10;15H', 'BOX TEST', '$'
t15_caption	db	'Box should be 20 wide, 10 tall, perfectly aligned$'

; --- Test 16 ---
t16_desc	db	'Test 16: Zork-style status line', 13, 10, 13, 10
		db	'Reverse-video status at row 1, body text at row 3+.$'
t16_seq		db	ESC, '[1;1H', ESC, '[7m'
		db	' West of House                Score: 0   Moves: 1               '
		db	ESC, '[0m', 13, 10, 13, 10
		db	'You are standing in an open field west of a white house, with a', 13, 10
		db	'boarded front door.', 13, 10
		db	'There is a small mailbox here.', 13, 10
		db	'$'
t16_caption	db	'Status line should be inverted, body wrapped at full width$'
