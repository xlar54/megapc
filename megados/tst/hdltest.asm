; HDLTEST.COM — tests handle/device behavior, IOCTL, DUP, seek methods
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; === Test 1: IOCTL AL=0 on each standard handle ===
	mov	si, msg_ioctl
	call	pstr
	call	nl
	xor	bx, bx
.ioctl_loop:
	cmp	bx, 5
	jae	.ioctl_done
	push	bx
	mov	dl, '0'
	add	dl, bl
	mov	ah, 0x02
	int	0x21
	mov	dl, '='
	mov	ah, 0x02
	int	0x21
	pop	bx
	push	bx
	mov	ax, 0x4400
	int	0x21
	jc	.ioctl_err
	mov	ax, dx
	call	phex
	jmp	.ioctl_next
.ioctl_err:
	mov	si, msg_err
	call	pstr
.ioctl_next:
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	bx
	inc	bx
	jmp	.ioctl_loop
.ioctl_done:
	call	nl

	; === Test 2: IOCTL AL=0 on invalid handle (should fail) ===
	mov	si, msg_ioctl_bad
	call	pstr
	mov	ax, 0x4400
	mov	bx, 99
	int	0x21
	jc	.ioctl_bad_ok
	mov	si, msg_fail
	call	pstr
	jmp	.ioctl_bad_done
.ioctl_bad_ok:
	mov	si, msg_ok
	call	pstr
.ioctl_bad_done:
	call	nl

	; === Test 3: IOCTL AL=6 input ready ===
	mov	si, msg_input_rdy
	call	pstr
	mov	ax, 0x4406
	mov	bx, 0		; stdin
	int	0x21
	xor	ah, ah
	call	phex
	call	nl

	; === Test 4: IOCTL AL=7 output ready ===
	mov	si, msg_output_rdy
	call	pstr
	mov	ax, 0x4407
	mov	bx, 1		; stdout
	int	0x21
	xor	ah, ah
	call	phex
	call	nl

	; === Test 5: IOCTL AL=8 removable ===
	mov	si, msg_removable
	call	pstr
	mov	ax, 0x4408
	mov	bx, 0		; drive A
	int	0x21
	jc	.rem_err
	call	phex
	jmp	.rem_done
.rem_err:
	mov	si, msg_err
	call	pstr
.rem_done:
	call	nl

	; === Test 6: IOCTL AL=1 set device info (should succeed) ===
	mov	si, msg_ioctl_set
	call	pstr
	mov	ax, 0x4401
	mov	bx, 1
	mov	dx, 0x00D3
	int	0x21
	jc	.set_err
	mov	si, msg_ok
	call	pstr
	jmp	.set_done
.set_err:
	mov	si, msg_fail
	call	pstr
.set_done:
	call	nl

	; === Test 7: Write to handle 0 (stdin) ===
	mov	si, msg_write0
	call	pstr
	mov	ah, 0x40
	mov	bx, 0
	mov	cx, 2
	mov	dx, msg_hi
	int	0x21
	jc	.w0_err
	call	phex
	jmp	.w0_done
.w0_err:
	mov	si, msg_err
	call	pstr
.w0_done:
	call	nl

	; === Test 8: Write to handle 4 (stdprn) ===
	mov	si, msg_write4
	call	pstr
	mov	ah, 0x40
	mov	bx, 4
	mov	cx, 2
	mov	dx, msg_hi
	int	0x21
	jc	.w4_err
	call	phex
	jmp	.w4_done
.w4_err:
	mov	si, msg_err
	call	pstr
.w4_done:
	call	nl

	; === Test 9: Create file, DUP handle, write via both ===
	mov	si, msg_dup
	call	pstr
	; Create TEST.TMP
	mov	ah, 0x3C
	mov	cx, 0
	mov	dx, fname_tmp
	int	0x21
	jc	.dup_create_err
	mov	[handle1], ax
	jmp	.dup_created
.dup_create_err:
	push	ax
	mov	si, msg_cr_err
	call	pstr
	pop	ax
	call	phex
	call	nl
	jmp	.dup_done
.dup_created:
	; DUP it
	mov	bx, [handle1]	; BX = handle from create
	mov	ah, 0x45
	int	0x21
	jc	.dup_err
	mov	[handle2], ax
	; Print both handles
	mov	ax, [handle1]
	call	phex
	mov	dl, '/'
	mov	ah, 0x02
	int	0x21
	mov	ax, [handle2]
	call	phex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	; Write "AB" via handle1
	mov	ah, 0x40
	mov	bx, [handle1]
	mov	cx, 2
	mov	dx, msg_ab
	int	0x21
	; Write "CD" via handle2
	mov	ah, 0x40
	mov	bx, [handle2]
	mov	cx, 2
	mov	dx, msg_cd
	int	0x21
	; Close both
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	mov	ah, 0x3E
	mov	bx, [handle2]
	int	0x21
	mov	si, msg_ok
	call	pstr
	jmp	.dup_done
.dup_err:
	mov	si, msg_fail
	call	pstr
.dup_done:
	call	nl

	; === Test 10: DUP2 — redirect handle 5 to stdout ===
	mov	si, msg_dup2
	call	pstr
	; Open TEST.TMP for read
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname_tmp
	int	0x21
	jc	.dup2_err
	mov	[handle1], ax
	; DUP2: force handle1 to be a copy of stdout (handle 1)
	mov	cx, [handle1]	; target = our file handle
	mov	ah, 0x46
	mov	bx, 1		; source = stdout
	int	0x21
	jc	.dup2_err
	mov	si, msg_ok
	call	pstr
	; Close
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	jmp	.dup2_done
.dup2_err:
	mov	si, msg_fail
	call	pstr
.dup2_done:
	call	nl

	; === Test 11: Seek method 1 (from current) ===
	mov	si, msg_seek1
	call	pstr
	; Open TEST.TMP
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname_tmp
	int	0x21
	jc	.sk1_err
	mov	[handle1], ax
	; Read 2 bytes (position now at 2)
	mov	bx, [handle1]
	mov	ah, 0x3F
	mov	cx, 2
	mov	dx, readbuf
	int	0x21
	; Seek +1 from current (method 1)
	mov	ah, 0x42
	mov	al, 1
	mov	bx, [handle1]
	xor	cx, cx
	mov	dx, 1
	int	0x21
	jc	.sk1_err
	; AX = new position (should be 3)
	call	phex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	; Read 1 byte (should be 'D' = 4th byte of "ABCD")
	mov	ah, 0x3F
	mov	bx, [handle1]
	mov	cx, 1
	mov	dx, readbuf
	int	0x21
	mov	dl, [readbuf]
	mov	ah, 0x02
	int	0x21
	; Close
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	jmp	.sk1_done
.sk1_err:
	mov	si, msg_fail
	call	pstr
.sk1_done:
	call	nl

	; === Test 12: Seek method 2 (from end) ===
	mov	si, msg_seek2
	call	pstr
	; Open TEST.TMP
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname_tmp
	int	0x21
	jc	.sk2_err
	mov	[handle1], ax
	; Seek -1 from end (method 2) — CX:DX = FFFF:FFFF = -1
	mov	bx, [handle1]
	mov	ax, 0x4202
	mov	cx, 0xFFFF
	mov	dx, 0xFFFF
	int	0x21
	jc	.sk2_err
	; AX = position (should be 3 for 4-byte file)
	call	phex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	; Read 1 byte (should be 'D')
	mov	ah, 0x3F
	mov	bx, [handle1]
	mov	cx, 1
	mov	dx, readbuf
	int	0x21
	mov	dl, [readbuf]
	mov	ah, 0x02
	int	0x21
	; Close
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	jmp	.sk2_done
.sk2_err:
	mov	si, msg_fail
	call	pstr
.sk2_done:
	call	nl

	; === Test 13: Seek on invalid handle ===
	mov	si, msg_seek_bad
	call	pstr
	mov	ah, 0x42
	mov	al, 0
	mov	bx, 7		; likely closed
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.skb_ok
	mov	si, msg_fail
	call	pstr
	jmp	.skb_done
.skb_ok:
	mov	si, msg_ok
	call	pstr
.skb_done:
	call	nl

	; === Test 14: Write CX=0 (truncate) ===
	mov	si, msg_trunc
	call	pstr
	; Open TEST.TMP for write
	mov	ah, 0x3D
	mov	al, 2		; read/write
	mov	dx, fname_tmp
	int	0x21
	jc	.tr_err
	mov	[handle1], ax
	; Seek to position 2
	mov	bx, [handle1]
	mov	ax, 0x4200
	xor	cx, cx
	mov	dx, 2
	int	0x21
	; Write 0 bytes = truncate
	mov	ah, 0x40
	mov	bx, [handle1]
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.tr_err
	; Seek to end to get size
	mov	ah, 0x42
	mov	al, 2
	mov	bx, [handle1]
	xor	cx, cx
	xor	dx, dx
	int	0x21
	; AX = file size (should be 2 after truncate)
	call	phex
	; Close
	mov	ah, 0x3E
	mov	bx, [handle1]
	int	0x21
	jmp	.tr_done
.tr_err:
	mov	si, msg_fail
	call	pstr
.tr_done:
	call	nl

	; === Clean up: delete TEST.TMP ===
	mov	ah, 0x41
	mov	dx, fname_tmp
	int	0x21

	; Done
	mov	ax, 0x4C00
	int	0x21

; --- Subroutines ---
pstr:
	lodsb
	or	al, al
	jz	.d
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	pstr
.d:	ret

nl:
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	ret

phex:
	push	cx
	push	dx
	mov	cx, 4
.h:	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.o
	add	al, 7
.o:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.h
	pop	dx
	pop	cx
	ret

; --- Data ---
msg_ioctl	db	'IOCTL 0-4:', 0
msg_ioctl_bad	db	'IOCTL bad hdl: ', 0
msg_input_rdy	db	'Input ready: ', 0
msg_output_rdy	db	'Output ready: ', 0
msg_removable	db	'Removable A: ', 0
msg_ioctl_set	db	'IOCTL set: ', 0
msg_write0	db	'Write hdl 0: ', 0
msg_write4	db	'Write hdl 4: ', 0
msg_dup		db	'DUP: ', 0
msg_dup2	db	'DUP2: ', 0
msg_seek1	db	'Seek from cur: ', 0
msg_seek2	db	'Seek from end: ', 0
msg_seek_bad	db	'Seek bad hdl: ', 0
msg_trunc	db	'Truncate: ', 0
msg_cr_err	db	'CREATE ERR=', 0
msg_ok		db	'OK', 0
msg_fail	db	'FAIL', 0
msg_err		db	'ERR', 0
msg_hi		db	'OK'
msg_ab		db	'AB'
msg_cd		db	'CD'
fname_tmp	db	'TEST.TMP', 0

handle1		dw	0
handle2		dw	0
readbuf		times 8 db 0
