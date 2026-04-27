; TRC21.COM — install INT 21h tracer (TSR), then run GWBASIC.EXE
; The tracer logs each INT 21h call's AH value into a circular buffer.
; After GWBASIC exits, the log is dumped to the screen.
;
; Usage: TRC21
;
; The log is in our own segment so it survives across the chained handler.
	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds

	; Save original INT 21h vector
	mov	ax, 0x3521
	int	0x21
	mov	[old21_off], bx
	mov	[old21_seg], es

	; Install our hook
	mov	ax, 0x2521
	mov	dx, hook21
	int	0x21

	; Reset log
	mov	word [log_count], 0

	; Print "running..." and run GWBASIC via DOS command
	; We can't EXEC, so we'll just present a message and the user types
	; the commands themselves. After they exit GWBASIC and run TRC21D,
	; the tracer will be active. Actually simpler approach: run an inline
	; sequence of file I/O ops that mirrors what GWBASIC's LOAD does.

	mov	ah, 0x09
	mov	dx, msg_open
	int	0x21

	; --- Call sequence A: handle-based open + 128-byte reads ---
	; Open A1.BAS
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.handle_err
	mov	[handle], ax

	; Read 128 bytes
	mov	ah, 0x09
	mov	dx, msg_r1
	int	0x21
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	jc	.read_err
	push	ax
	mov	ah, 0x09
	mov	dx, msg_got
	int	0x21
	pop	ax
	call	print_dec
	call	newline

	; Read 128 more
	mov	ah, 0x09
	mov	dx, msg_r2
	int	0x21
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	jc	.read_err
	push	ax
	mov	ah, 0x09
	mov	dx, msg_got
	int	0x21
	pop	ax
	call	print_dec
	call	newline

	; Close handle
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	jmp	.byte_test

.handle_err:
	mov	ah, 0x09
	mov	dx, msg_h_err
	int	0x21
	jmp	.byte_test
.read_err:
	mov	ah, 0x09
	mov	dx, msg_r_err
	int	0x21

.byte_test:
	; --- Call sequence A5: 1-byte detection read + 128-byte refill reads ---
	; (this mimics GW-BASIC LOAD's ASCII-vs-tokenized detection step)
	mov	ah, 0x09
	mov	dx, msg_detect
	int	0x21
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.detect_skip
	mov	[handle], ax
	; Read 1 byte (detection)
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_d1
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	; Read 128 bytes
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_d2
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	; Read 128 more
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_d3
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
.detect_skip:

	; --- Call sequence A4: open + seek-to-end + seek-back + read pattern ---
	; (mimics what GW-BASIC LOAD likely does)
	mov	ah, 0x09
	mov	dx, msg_seek
	int	0x21
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.seek_skip
	mov	[handle], ax
	; Seek to end (method 2, offset 0)
	mov	ah, 0x42
	mov	al, 2
	mov	bx, [handle]
	xor	cx, cx
	xor	dx, dx
	int	0x21
	; AX = file size low (DX = high)
	push	ax
	mov	ah, 0x09
	mov	dx, msg_size
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	; Seek back to start (method 0, offset 0)
	mov	ah, 0x42
	mov	al, 0
	mov	bx, [handle]
	xor	cx, cx
	xor	dx, dx
	int	0x21
	; Now read 128 bytes
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_after_seek1
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	; Read 128 more
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_after_seek2
	int	0x21
	pop	ax
	call	print_dec
	call	newline
	; Close
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
.seek_skip:

	; --- Call sequence A3: try various CX sizes to find one that breaks ---
	mov	ah, 0x09
	mov	dx, msg_var
	int	0x21
	; Test sizes: 64, 100, 128, 200, 256, 232
	mov	si, sizes
	mov	cx, 6			; number of sizes to try
.var_loop:
	push	cx
	push	si
	mov	ax, [si]
	mov	[size_to_try], ax
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.var_skip
	mov	[handle], ax
	; First read with chosen size
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, [size_to_try]
	mov	dx, buf
	int	0x21
	push	ax
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, [size_to_try]
	mov	dx, buf
	int	0x21
	mov	bp, ax			; bp = 2nd-read result
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	; Print: "<size>: <r1>+<r2>"
	mov	ax, [size_to_try]
	call	print_dec
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	ax
	call	print_dec
	mov	dl, '+'
	mov	ah, 0x02
	int	0x21
	mov	ax, bp
	call	print_dec
	call	newline
.var_skip:
	pop	si
	pop	cx
	add	si, 2
	loop	.var_loop

	; --- Call sequence A2: byte-at-a-time reads of A1.BAS via AH=3F.
	; If GW-BASIC reads one byte at a time (refilling an internal line buffer),
	; the bug would surface here. Read 232 bytes one at a time, count matches.
	mov	ah, 0x09
	mov	dx, msg_byte
	int	0x21
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.byte_done
	mov	[handle], ax
	xor	si, si			; bytes successfully read
.byte_loop:
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1
	mov	dx, buf
	int	0x21
	jc	.byte_close
	cmp	ax, 0
	je	.byte_close
	inc	si
	cmp	si, 300			; safety cap
	jb	.byte_loop
.byte_close:
	mov	bx, [handle]
	mov	ah, 0x3E
	int	0x21
	mov	ax, si
	call	print_dec
	mov	ah, 0x09
	mov	dx, msg_bytes_got
	int	0x21
.byte_done:

.fcb_test:
	; --- Call sequence B: FCB-based open + 128-byte reads ---
	push	cs
	pop	es			; force ES=CS so rep movsb writes to our seg
	push	cs
	pop	ds
	mov	ah, 0x09
	mov	dx, msg_fcb
	int	0x21

	; Build FCB at fcb for A1.BAS (small file — triggers partial-record-at-EOF
	; on the second AH=14 read).
	mov	di, fcb
	xor	al, al
	mov	[di], al		; drive
	inc	di
	mov	si, fcb_name
	mov	cx, 11
	cld
	rep	movsb

	; Dump FCB bytes 0..11 for verification
	mov	ah, 0x09
	mov	dx, msg_fcb_dump
	int	0x21
	mov	si, fcb
	mov	cx, 12
.dump_loop:
	push	cx
	push	si
	mov	dl, [si]
	cmp	dl, 0x20
	jae	.dump_print
	; control char — print as <NN>
	mov	dl, '<'
	mov	ah, 0x02
	int	0x21
	pop	si
	push	si
	mov	al, [si]
	xor	ah, ah
	call	print_dec
	mov	dl, '>'
	mov	ah, 0x02
	int	0x21
	jmp	.dump_next
.dump_print:
	mov	ah, 0x02
	int	0x21
.dump_next:
	pop	si
	pop	cx
	inc	si
	loop	.dump_loop
	call	newline

	; Open FCB (AH=0F)
	mov	ah, 0x0F
	mov	dx, fcb
	int	0x21
	cmp	al, 0
	jne	.fcb_open_err

	; Set DTA to our buffer (AH=1A)
	mov	ah, 0x1A
	mov	dx, buf
	int	0x21

	; Set FCB record size to 128
	mov	word [fcb + 0x0E], 128

	; Sequential read (AH=14)
	mov	ah, 0x09
	mov	dx, msg_fr1
	int	0x21
	mov	ah, 0x14
	mov	dx, fcb
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_al
	int	0x21
	pop	ax
	push	ax
	xor	ah, ah
	call	print_dec
	pop	ax
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 'b'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'l'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'k'
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	mov	ax, [fcb + 0x0C]
	call	print_dec
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 'r'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'e'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'c'
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	xor	ah, ah
	mov	al, [fcb + 0x20]
	call	print_dec
	call	newline

	; Sequential read (AH=14) again
	mov	ah, 0x09
	mov	dx, msg_fr2
	int	0x21
	mov	ah, 0x14
	mov	dx, fcb
	int	0x21
	push	ax
	mov	ah, 0x09
	mov	dx, msg_al
	int	0x21
	pop	ax
	push	ax
	xor	ah, ah
	call	print_dec
	pop	ax
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 'b'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'l'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'k'
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	mov	ax, [fcb + 0x0C]
	call	print_dec
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	dl, 'r'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'e'
	mov	ah, 0x02
	int	0x21
	mov	dl, 'c'
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	xor	ah, ah
	mov	al, [fcb + 0x20]
	call	print_dec
	call	newline

	; Close FCB (AH=10)
	mov	ah, 0x10
	mov	dx, fcb
	int	0x21

	jmp	.exit

.fcb_open_err:
	mov	ah, 0x09
	mov	dx, msg_fo_err
	int	0x21

.exit:
	; Restore INT 21h
	push	ds
	lds	dx, [old21_off]
	mov	ax, 0x2521
	int	0x21
	pop	ds

	mov	ah, 0x4C
	mov	al, 0
	int	0x21

; --- INT 21h hook ---
hook21:
	; We just chain to the original handler. Logging is omitted to keep
	; the test simple — instead the test runs the calls inline above.
	jmp	far [cs:old21_off]

print_dec:
	push	ax
	push	bx
	push	cx
	push	dx
	mov	bx, 10
	xor	cx, cx
.pd_div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_div
.pd_emit:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	loop	.pd_emit
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

old21_off	dw	0
old21_seg	dw	0
log_count	dw	0
handle		dw	0
size_to_try	dw	0
sizes		dw	64, 100, 128, 200, 256, 232

fname		db	'A1.BAS', 0
fcb_name	db	'A1      BAS'
fcb_name_rdme	db	'README  TXT'
fcb		times 37 db 0
buf		times 256 db 0

msg_open	db	'-- handle path --', 0x0D, 0x0A, '$'
msg_r1		db	'AH=3F #1 ', '$'
msg_r2		db	'AH=3F #2 ', '$'
msg_got		db	'returned ', '$'
msg_h_err	db	'AH=3D failed', 0x0D, 0x0A, '$'
msg_r_err	db	'read CF=1', 0x0D, 0x0A, '$'

msg_fcb		db	'-- FCB path --', 0x0D, 0x0A, '$'
msg_fcb_dump	db	'FCB[0..11]: ', '$'
msg_byte	db	'-- byte-at-a-time AH=3F --', 0x0D, 0x0A, '$'
msg_var		db	'-- AH=3F two-read sizes (CX:r1+r2) --', 0x0D, 0x0A, '$'
msg_seek	db	'-- seek-to-end + seek-back + 2 reads --', 0x0D, 0x0A, '$'
msg_detect	db	'-- 1-byte detect + 2x 128-byte reads --', 0x0D, 0x0A, '$'
msg_d1		db	'  detect=', '$'
msg_d2		db	'  read1=', '$'
msg_d3		db	'  read2=', '$'
msg_size	db	'  size=', '$'
msg_after_seek1	db	'  read1=', '$'
msg_after_seek2	db	'  read2=', '$'
msg_bytes_got	db	' bytes via CX=1 reads', 0x0D, 0x0A, '$'
msg_fr1		db	'AH=14 #1 ', '$'
msg_fr2		db	'AH=14 #2 ', '$'
msg_al		db	'AL=', '$'
msg_fo_err	db	'AH=0F failed', 0x0D, 0x0A, '$'
