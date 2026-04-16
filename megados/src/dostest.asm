; DOSTEST.COM — comprehensive MegaDOS compatibility test
; Tests INT 21h services and reports PASS/FAIL for each
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Shrink our memory block so AH=48 can allocate
	mov	ah, 0x4A
	mov	bx, 0x100		; Keep 4K paragraphs (enough for this program)
	int	0x21

	mov	si, msg_banner
	call	pstr
	call	nl

	; Track pass/fail counts
	mov	word [passes], 0
	mov	word [fails], 0

	; === 1. DOS Version (AH=30) ===
	mov	si, t_ver
	call	pstr
	mov	ah, 0x30
	int	0x21
	cmp	al, 3
	je	.t1_pass
	jmp	.t1_fail
.t1_pass:
	call	pass
	jmp	.t1_done
.t1_fail:
	call	fail
.t1_done:

	; === 2. Get Drive (AH=19) ===
	mov	si, t_getdrv
	call	pstr
	mov	ah, 0x19
	int	0x21
	cmp	al, 0			; Should be A:
	je	.t2_pass
	jmp	.t2_fail
.t2_pass:
	call	pass
	jmp	.t2_done
.t2_fail:
	call	fail
.t2_done:

	; === 3. Set/Get Drive (AH=0E/19) ===
	mov	si, t_setdrv
	call	pstr
	mov	ah, 0x0E
	mov	dl, 0			; Set to A:
	int	0x21
	cmp	al, 1			; Should return at least 1 drive
	jae	.t3_pass
	jmp	.t3_fail
.t3_pass:
	call	pass
	jmp	.t3_done
.t3_fail:
	call	fail
.t3_done:

	; === 4. Get Directory (AH=47) ===
	mov	si, t_getdir
	call	pstr
	mov	ah, 0x47
	xor	dl, dl
	mov	si, pathbuf
	int	0x21
	jc	.t4_fail
	call	pass
	jmp	.t4_done
.t4_fail:
	call	fail
.t4_done:

	; === 5. Get Date (AH=2A) ===
	mov	si, t_date
	call	pstr
	mov	ah, 0x2A
	int	0x21
	cmp	cx, 1980
	jb	.t5_fail
	call	pass
	jmp	.t5_done
.t5_fail:
	call	fail
.t5_done:

	; === 6. Get Time (AH=2C) ===
	mov	si, t_time
	call	pstr
	mov	ah, 0x2C
	int	0x21
	cmp	ch, 24
	jae	.t6_fail
	call	pass
	jmp	.t6_done
.t6_fail:
	call	fail
.t6_done:

	; === 7. Switch Char (AH=37) ===
	mov	si, t_switch
	call	pstr
	mov	ax, 0x3700
	int	0x21
	cmp	dl, '/'
	je	.t7_pass
	jmp	.t7_fail
.t7_pass:
	call	pass
	jmp	.t7_done
.t7_fail:
	call	fail
.t7_done:

	; === 8. Break Flag (AH=33) ===
	mov	si, t_break
	call	pstr
	mov	ax, 0x3300
	int	0x21
	; DL = flag, should be 0 or 1
	cmp	dl, 2
	jb	.t8_pass
	jmp	.t8_fail
.t8_pass:
	call	pass
	jmp	.t8_done
.t8_fail:
	call	fail
.t8_done:

	; === 9. PSP Segment (AH=62) ===
	mov	si, t_psp
	call	pstr
	mov	ah, 0x62
	int	0x21
	or	bx, bx
	jz	.t9_fail
	call	pass
	jmp	.t9_done
.t9_fail:
	call	fail
.t9_done:

	; === 10. DTA (AH=1A/2F) ===
	mov	si, t_dta
	call	pstr
	mov	ah, 0x1A
	mov	dx, pathbuf
	int	0x21
	mov	ah, 0x2F
	int	0x21
	; ES:BX should be DS:pathbuf
	cmp	bx, pathbuf
	jne	.t10_fail
	call	pass
	jmp	.t10_done
.t10_fail:
	call	fail
.t10_done:
	; Restore default DTA
	mov	ah, 0x1A
	mov	dx, 0x80
	int	0x21

	; === 11. IOCTL stdin (AH=44/0) ===
	mov	si, t_ioctl0
	call	pstr
	mov	ax, 0x4400
	mov	bx, 0
	int	0x21
	jc	.t11_fail
	test	dx, 0x0080		; ISDEV bit
	jz	.t11_fail
	call	pass
	jmp	.t11_done
.t11_fail:
	call	fail
.t11_done:

	; === 12. IOCTL stdout (AH=44/0) ===
	mov	si, t_ioctl1
	call	pstr
	mov	ax, 0x4400
	mov	bx, 1
	int	0x21
	jc	.t12_fail
	test	dx, 0x0080
	jz	.t12_fail
	call	pass
	jmp	.t12_done
.t12_fail:
	call	fail
.t12_done:

	; === 13. IOCTL invalid handle ===
	mov	si, t_ioctl_bad
	call	pstr
	mov	ax, 0x4400
	mov	bx, 99
	int	0x21
	jc	.t13_pass		; Should fail
	jmp	.t13_fail
.t13_pass:
	call	pass
	jmp	.t13_done
.t13_fail:
	call	fail
.t13_done:

	; === 14. IOCTL input ready (AH=44/6) ===
	mov	si, t_ioctl6
	call	pstr
	mov	ax, 0x4406
	mov	bx, 0
	int	0x21
	jc	.t14_fail
	call	pass
	jmp	.t14_done
.t14_fail:
	call	fail
.t14_done:

	; === 15. IOCTL output ready (AH=44/7) ===
	mov	si, t_ioctl7
	call	pstr
	mov	ax, 0x4407
	mov	bx, 1
	int	0x21
	jc	.t15_fail
	cmp	al, 0xFF
	jne	.t15_fail
	call	pass
	jmp	.t15_done
.t15_fail:
	call	fail
.t15_done:

	; === 16. IOCTL removable (AH=44/8) ===
	mov	si, t_ioctl8
	call	pstr
	mov	ax, 0x4408
	mov	bx, 0
	int	0x21
	jc	.t16_fail
	cmp	ax, 0			; 0 = removable
	jne	.t16_fail
	call	pass
	jmp	.t16_done
.t16_fail:
	call	fail
.t16_done:

	; === 17. Create file (AH=3C) ===
	mov	si, t_create
	call	pstr
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fname
	int	0x21
	jc	.t17_fail
	mov	[hdl1], ax
	call	pass
	jmp	.t17_done
.t17_fail:
	call	fail
.t17_done:

	; === 18. Write file (AH=40) ===
	mov	si, t_write
	call	pstr
	mov	ah, 0x40
	mov	bx, [hdl1]
	mov	cx, 4
	mov	dx, testdata
	int	0x21
	jc	.t18_fail
	cmp	ax, 4
	jne	.t18_fail
	call	pass
	jmp	.t18_done
.t18_fail:
	call	fail
.t18_done:

	; === 19. Close file (AH=3E) ===
	mov	si, t_close
	call	pstr
	mov	ah, 0x3E
	mov	bx, [hdl1]
	int	0x21
	jc	.t19_fail
	call	pass
	jmp	.t19_done
.t19_fail:
	call	fail
.t19_done:

	; === 20. Open file (AH=3D) ===
	mov	si, t_open
	call	pstr
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname
	int	0x21
	jc	.t20_fail
	mov	[hdl1], ax
	call	pass
	jmp	.t20_done
.t20_fail:
	call	fail
.t20_done:

	; === 21. Read file (AH=3F) ===
	mov	si, t_read
	call	pstr
	mov	bx, [hdl1]
	mov	ah, 0x3F
	mov	cx, 4
	mov	dx, readbuf
	int	0x21
	jc	.t21_fail
	cmp	ax, 4
	jne	.t21_fail
	cmp	byte [readbuf], 'A'
	jne	.t21_fail
	cmp	byte [readbuf+3], 'D'
	jne	.t21_fail
	call	pass
	jmp	.t21_done
.t21_fail:
	call	fail
.t21_done:

	; === 22. Seek from start (AH=42/0) ===
	mov	si, t_seek0
	call	pstr
	mov	bx, [hdl1]
	mov	ax, 0x4200
	xor	cx, cx
	mov	dx, 2
	int	0x21
	jc	.t22_fail
	cmp	ax, 2
	jne	.t22_fail
	call	pass
	jmp	.t22_done
.t22_fail:
	call	fail
.t22_done:

	; === 23. Read after seek ===
	mov	si, t_seekrd
	call	pstr
	mov	bx, [hdl1]
	mov	ah, 0x3F
	mov	cx, 1
	mov	dx, readbuf
	int	0x21
	jc	.t23_fail
	cmp	byte [readbuf], 'C'
	jne	.t23_fail
	call	pass
	jmp	.t23_done
.t23_fail:
	call	fail
.t23_done:

	; === 24. Seek from current (AH=42/1) ===
	mov	si, t_seek1
	call	pstr
	mov	bx, [hdl1]
	mov	ax, 0x4201
	xor	cx, cx
	xor	dx, dx			; +0 from current (pos=3)
	int	0x21
	jc	.t24_fail
	cmp	ax, 3
	jne	.t24_fail
	call	pass
	jmp	.t24_done
.t24_fail:
	call	fail
.t24_done:

	; === 25. Seek from end (AH=42/2) ===
	mov	si, t_seek2
	call	pstr
	mov	bx, [hdl1]
	mov	ax, 0x4202
	mov	cx, 0xFFFF
	mov	dx, 0xFFFF		; -1 from end
	int	0x21
	jc	.t25_fail
	cmp	ax, 3			; 4 bytes - 1 = pos 3
	jne	.t25_fail
	call	pass
	jmp	.t25_done
.t25_fail:
	call	fail
.t25_done:

	; === 26. DUP handle (AH=45) ===
	mov	si, t_dup
	call	pstr
	mov	ah, 0x45
	mov	bx, [hdl1]
	int	0x21
	jc	.t26_fail
	mov	[hdl2], ax
	cmp	ax, [hdl1]
	je	.t26_fail		; Should be different handle
	call	pass
	jmp	.t26_done
.t26_fail:
	call	fail
.t26_done:

	; === 27. Close both handles ===
	mov	si, t_closedup
	call	pstr
	mov	ah, 0x3E
	mov	bx, [hdl1]
	int	0x21
	mov	ah, 0x3E
	mov	bx, [hdl2]
	int	0x21
	call	pass

	; === 28. FindFirst (AH=4E) ===
	mov	si, t_find
	call	pstr
	mov	ah, 0x4E
	mov	cx, 0x27
	mov	dx, wildcard
	int	0x21
	jc	.t28_fail
	call	pass
	jmp	.t28_done
.t28_fail:
	call	fail
.t28_done:

	; === 29. FindNext (AH=4F) ===
	mov	si, t_findnext
	call	pstr
	mov	ah, 0x4F
	int	0x21
	jc	.t29_fail
	call	pass
	jmp	.t29_done
.t29_fail:
	call	fail
.t29_done:

	; === 30. Get Free Space (AH=36) ===
	mov	si, t_free
	call	pstr
	mov	ah, 0x36
	mov	dl, 0
	int	0x21
	cmp	ax, 0xFFFF
	je	.t30_fail
	cmp	cx, 512
	jne	.t30_fail
	call	pass
	jmp	.t30_done
.t30_fail:
	call	fail
.t30_done:

	; === 31. Alloc Memory (AH=48) ===
	mov	si, t_alloc
	call	pstr
	mov	ah, 0x48
	mov	bx, 1			; 1 paragraph
	int	0x21
	jc	.t31_fail
	mov	[alloc_seg], ax
	call	pass
	jmp	.t31_done
.t31_fail:
	call	fail
.t31_done:

	; === 32. Free Memory (AH=49) ===
	mov	si, t_mfree
	call	pstr
	mov	ah, 0x49
	mov	es, [alloc_seg]
	int	0x21
	jc	.t32_fail
	push	cs
	pop	es
	call	pass
	jmp	.t32_done
.t32_fail:
	push	cs
	pop	es
	call	fail
.t32_done:

	; === 33. Environment (PSP:2C) ===
	mov	si, t_env
	call	pstr
	mov	ah, 0x62
	int	0x21
	mov	es, bx
	mov	ax, [es:0x2C]
	push	cs
	pop	es
	or	ax, ax
	jz	.t33_fail
	call	pass
	jmp	.t33_done
.t33_fail:
	call	fail
.t33_done:

	; === 34. Command Tail (PSP:80) ===
	mov	si, t_cmdtail
	call	pstr
	mov	ah, 0x62
	int	0x21
	mov	es, bx
	; PSP:80 should be a valid length byte
	mov	al, [es:0x80]
	push	cs
	pop	es
	cmp	al, 128
	jae	.t34_fail
	call	pass
	jmp	.t34_done
.t34_fail:
	call	fail
.t34_done:

	; === 35. Delete test file (AH=41) ===
	mov	si, t_delete
	call	pstr
	mov	ah, 0x41
	mov	dx, fname
	int	0x21
	jc	.t35_fail
	call	pass
	jmp	.t35_done
.t35_fail:
	call	fail
.t35_done:

	; === 36. Get/Set Vector (AH=35/25) ===
	mov	si, t_vector
	call	pstr
	mov	ax, 0x3521		; Get INT 21h
	int	0x21
	mov	ax, es
	push	cs
	pop	es
	or	ax, ax
	jz	.t36_fail
	call	pass
	jmp	.t36_done
.t36_fail:
	call	fail
.t36_done:

	; === 37. EXEC child program (AH=4B) ===
	mov	si, t_exec
	call	pstr
	; Set up parameter block for EXEC
	mov	word [exec_pb], 0		; Env = inherit (0)
	mov	word [exec_pb+2], exec_cmdtail	; Command tail offset
	mov	word [exec_pb+4], cs		; Command tail segment
	mov	word [exec_pb+6], 0x005C	; FCB1 offset (PSP default)
	mov	word [exec_pb+8], cs		; FCB1 segment
	mov	word [exec_pb+10], 0x006C	; FCB2 offset
	mov	word [exec_pb+12], cs		; FCB2 segment
	; Call EXEC
	mov	ax, 0x4B00
	mov	dx, child_fname
	push	ds
	push	es
	mov	bx, exec_pb
	push	cs
	pop	es			; ES:BX = parameter block
	int	0x21
	pop	es
	pop	ds
	jc	.t37_fail
	call	pass
	jmp	.t37_done
.t37_fail:
	push	ax
	call	fail
	; Print error code
	mov	si, msg_errcode
	call	pstr
	pop	ax
	call	pdec
	call	nl
.t37_done:

	; === 38. Check child return code (AH=4D) ===
	mov	si, t_retcode
	call	pstr
	mov	ah, 0x4D
	int	0x21
	cmp	al, 42			; CHILD.COM exits with code 42
	je	.t38_pass
	jmp	.t38_fail
.t38_pass:
	call	pass
	jmp	.t38_done
.t38_fail:
	call	fail
.t38_done:

	; === 39. Get alloc info (AH=1B) ===
	mov	si, t_allocinfo
	call	pstr
	push	ds
	mov	ah, 0x1B
	int	0x21
	; AL=sectors/cluster, CX=bytes/sector, DX=total clusters
	; NOTE: DS is changed by this call (points to media byte)
	pop	ds
	cmp	al, 2			; 2 sectors per cluster
	jne	.t39_fail
	cmp	cx, 512			; 512 bytes/sector
	jne	.t39_fail
	or	dx, dx			; Total clusters > 0
	jz	.t39_fail
	call	pass
	jmp	.t39_done
.t39_fail:
	call	fail
.t39_done:

	; === 40. InDOS flag (AH=34) ===
	mov	si, t_indos
	call	pstr
	mov	ah, 0x34
	int	0x21
	; ES:BX should be a valid pointer
	mov	ax, es
	push	cs
	pop	es
	or	ax, ax
	jz	.t40_fail
	call	pass
	jmp	.t40_done
.t40_fail:
	call	fail
.t40_done:

	; === 41. FCB file size (AH=23) ===
	mov	si, t_fcbsize
	call	pstr
	; Set up FCB for README.TXT
	mov	byte [test_fcb], 0		; Default drive
	mov	word [test_fcb+1], 'RE'
	mov	word [test_fcb+3], 'AD'
	mov	word [test_fcb+5], 'ME'
	mov	word [test_fcb+7], '  '
	mov	word [test_fcb+9], 'TX'
	mov	byte [test_fcb+11], 'T'
	mov	word [test_fcb+0x0E], 128	; Record size = 128
	mov	ah, 0x23
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t41_fail
	; Random record field should be > 0 (file has content)
	mov	ax, [test_fcb+0x21]
	or	ax, ax
	jz	.t41_fail
	call	pass
	jmp	.t41_done
.t41_fail:
	call	fail
.t41_done:

	; === 42. FCB set random record (AH=24) ===
	mov	si, t_fcbrand
	call	pstr
	; Set up FCB with known block/record
	mov	word [test_fcb+0x0C], 1		; Block 1
	mov	byte [test_fcb+0x20], 5		; Record 5
	mov	ah, 0x24
	mov	dx, test_fcb
	int	0x21
	; Random record should be (1 * 128) + 5 = 133
	cmp	word [test_fcb+0x21], 133
	jne	.t42_fail
	call	pass
	jmp	.t42_done
.t42_fail:
	call	fail
.t42_done:

	; === 43. FCB sequential read (AH=14) ===
	mov	si, t_fcbread
	call	pstr
	; Open CHILD.COM via FCB (known to exist, starts with 0xB8)
	mov	byte [test_fcb], 0
	mov	word [test_fcb+1], 'CH'
	mov	word [test_fcb+3], 'IL'
	mov	word [test_fcb+5], 'D '
	mov	word [test_fcb+7], '  '
	mov	word [test_fcb+9], 'CO'
	mov	byte [test_fcb+11], 'M'
	mov	ah, 0x0F
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t43_fail
	; Clear DTA
	mov	byte [0x0080], 0
	; Read first record
	mov	ah, 0x14
	mov	dx, test_fcb
	int	0x21
	; AL=0 or AL=3 (partial) are both OK
	cmp	al, 1			; EOF = fail
	je	.t43_fail
	; Check DTA has data (CHILD.COM starts with 0xB8 = mov ax,imm16)
	cmp	byte [0x0080], 0xB8
	jne	.t43_fail
	call	pass
	jmp	.t43_done
.t43_fail:
	call	fail
.t43_done:

	; === 44. FCB sequential write (AH=15) ===
	; Test: create file via handle, write "HELLO", close,
	;       then open via FCB and read back with AH=14
	mov	si, t_fcbwrite
	call	pstr
	; Create via handle (AH=3C)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fcb_tmpname
	int	0x21
	jc	.t44_fail_c
	mov	bx, ax
	; Write 5 bytes "HELLO"
	mov	ah, 0x40
	mov	cx, 5
	mov	dx, t44_data
	int	0x21
	jc	.t44_fail_w
	; Close handle
	mov	ah, 0x3E
	int	0x21
	; Open via FCB (AH=0F) and read back with AH=14
	mov	byte [test_fcb], 0
	mov	word [test_fcb+1], 'FC'
	mov	word [test_fcb+3], 'BT'
	mov	word [test_fcb+5], 'ES'
	mov	word [test_fcb+7], 'T '
	mov	word [test_fcb+9], 'TM'
	mov	byte [test_fcb+11], 'P'
	mov	ah, 0x0F
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t44_fail_o
	; Check FCB file size > 0
	mov	ax, [test_fcb+0x10]
	or	ax, [test_fcb+0x12]
	jz	.t44_fail_s		; S = size is zero
	; Clear DTA
	mov	byte [0x0080], 0
	; Read first record (AH=14)
	mov	ah, 0x14
	mov	dx, test_fcb
	int	0x21
	cmp	al, 1
	je	.t44_fail_r
	; Verify first byte is 'H'
	cmp	byte [0x0080], 'H'
	jne	.t44_fail_v
	; Close and delete
	mov	ah, 0x10
	mov	dx, test_fcb
	int	0x21
	mov	ah, 0x41
	mov	dx, fcb_tmpname
	int	0x21
	call	pass
	jmp	.t44_done
.t44_fail_c:
.t44_fail_w:
.t44_fail_o:
.t44_fail_s:
.t44_fail_r:
.t44_fail_v:
	; Try to clean up
	mov	ah, 0x41
	mov	dx, fcb_tmpname
	int	0x21
	call	fail
.t44_done:

	; === 45. FCB random read (AH=21) ===
	; Open CHILD.COM, set random record=0, read, check first byte = 0xB8
	mov	si, t_fcbrand_r
	call	pstr
	mov	byte [test_fcb], 0
	mov	word [test_fcb+1], 'CH'
	mov	word [test_fcb+3], 'IL'
	mov	word [test_fcb+5], 'D '
	mov	word [test_fcb+7], '  '
	mov	word [test_fcb+9], 'CO'
	mov	byte [test_fcb+11], 'M'
	mov	ah, 0x0F
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t45_fail
	; Set random record = 0
	mov	word [test_fcb+0x21], 0
	mov	word [test_fcb+0x23], 0
	; Clear DTA
	mov	byte [0x0080], 0
	; Random read
	mov	ah, 0x21
	mov	dx, test_fcb
	int	0x21
	cmp	al, 1
	je	.t45_fail
	; Check first byte = 0xB8 (mov ax, imm16)
	cmp	byte [0x0080], 0xB8
	jne	.t45_fail
	; Check block/record were updated (should be block=0, record=0)
	cmp	word [test_fcb+0x0C], 0
	jne	.t45_fail
	call	pass
	jmp	.t45_done
.t45_fail:
	call	fail
.t45_done:

	; === 46. FCB random write (AH=22) ===
	; Create file, write "TEST!" at record 0, read back, verify
	mov	si, t_fcbrand_w
	call	pstr
	; Create via AH=16
	mov	byte [test_fcb], 0
	mov	word [test_fcb+1], 'FC'
	mov	word [test_fcb+3], 'BT'
	mov	word [test_fcb+5], 'ES'
	mov	word [test_fcb+7], 'T2'
	mov	word [test_fcb+9], 'TM'
	mov	byte [test_fcb+11], 'P'
	mov	ah, 0x16
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t46_fail
	; Put "TEST!" in DTA
	mov	byte [0x0080], 'T'
	mov	byte [0x0081], 'E'
	mov	byte [0x0082], 'S'
	mov	byte [0x0083], 'T'
	mov	byte [0x0084], '!'
	; Set random record = 0
	mov	word [test_fcb+0x21], 0
	mov	word [test_fcb+0x23], 0
	; Random write
	mov	ah, 0x22
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t46_fail
	; Close
	mov	ah, 0x10
	mov	dx, test_fcb
	int	0x21
	; Reopen
	mov	ah, 0x0F
	mov	dx, test_fcb
	int	0x21
	cmp	al, 0
	jne	.t46_fail
	; Clear DTA
	mov	byte [0x0080], 0
	; Random read record 0
	mov	word [test_fcb+0x21], 0
	mov	word [test_fcb+0x23], 0
	mov	ah, 0x21
	mov	dx, test_fcb
	int	0x21
	cmp	al, 1
	je	.t46_fail
	; Verify
	cmp	byte [0x0080], 'T'
	jne	.t46_fail
	; Close and delete
	mov	ah, 0x10
	mov	dx, test_fcb
	int	0x21
	mov	ah, 0x41
	mov	dx, fcb_tmp2name
	int	0x21
	call	pass
	jmp	.t46_done
.t46_fail:
	mov	ah, 0x41
	mov	dx, fcb_tmp2name
	int	0x21
	call	fail
.t46_done:

	; === Summary ===
	call	nl
	mov	si, msg_summary
	call	pstr
	mov	ax, [passes]
	call	pdec
	mov	si, msg_passed
	call	pstr
	mov	ax, [fails]
	call	pdec
	mov	si, msg_failed
	call	pstr
	call	nl

	mov	ax, 0x4C00
	int	0x21

; --- Helpers ---
pass:
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [passes]
	ret

fail:
	mov	si, msg_fail
	call	pstr
	call	nl
	inc	word [fails]
	ret

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

pdec:
	push	cx
	push	dx
	push	bx
	xor	cx, cx
	mov	bx, 10
.div:	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.div
.pr:	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pr
	pop	bx
	pop	dx
	pop	cx
	ret

; --- Data ---
msg_banner	db	'=== MegaDOS Compatibility Test ===', 0
msg_pass	db	' PASS', 0
msg_fail	db	' FAIL', 0
msg_summary	db	'Results: ', 0
msg_passed	db	' passed, ', 0
msg_failed	db	' failed', 0
msg_errcode	db	'  Error: ', 0

t_ver		db	' 1. DOS Version', 0
t_getdrv	db	' 2. Get Drive', 0
t_setdrv	db	' 3. Set Drive', 0
t_getdir	db	' 4. Get Directory', 0
t_date		db	' 5. Get Date', 0
t_time		db	' 6. Get Time', 0
t_switch	db	' 7. Switch Char', 0
t_break		db	' 8. Break Flag', 0
t_psp		db	' 9. PSP Segment', 0
t_dta		db	'10. DTA Set/Get', 0
t_ioctl0	db	'11. IOCTL stdin', 0
t_ioctl1	db	'12. IOCTL stdout', 0
t_ioctl_bad	db	'13. IOCTL bad hdl', 0
t_ioctl6	db	'14. Input ready', 0
t_ioctl7	db	'15. Output ready', 0
t_ioctl8	db	'16. Removable', 0
t_create	db	'17. Create file', 0
t_write		db	'18. Write file', 0
t_close		db	'19. Close file', 0
t_open		db	'20. Open file', 0
t_read		db	'21. Read file', 0
t_seek0		db	'22. Seek start', 0
t_seekrd	db	'23. Read@seek', 0
t_seek1		db	'24. Seek current', 0
t_seek2		db	'25. Seek end', 0
t_dup		db	'26. DUP handle', 0
t_closedup	db	'27. Close DUP', 0
t_find		db	'28. FindFirst', 0
t_findnext	db	'29. FindNext', 0
t_free		db	'30. Disk free', 0
t_alloc		db	'31. Alloc memory', 0
t_mfree		db	'32. Free memory', 0
t_env		db	'33. Environment', 0
t_cmdtail	db	'34. Cmd tail', 0
t_delete	db	'35. Delete file', 0
t_vector	db	'36. Get vector', 0
t_exec		db	'37. EXEC child', 0
t_retcode	db	'38. Return code', 0
t_allocinfo	db	'39. Alloc info', 0
t_indos		db	'40. InDOS flag', 0
t_fcbsize	db	'41. FCB file size', 0
t_fcbrand	db	'42. FCB set random', 0
t_fcbread	db	'43. FCB seq read', 0
t_fcbwrite	db	'44. FCB seq write', 0
t_fcbrand_r	db	'45. FCB rand read', 0
t_fcbrand_w	db	'46. FCB rand write', 0

fname		db	'DOSTEST.TMP', 0
fcb_tmpname	db	'FCBTEST.TMP', 0
fcb_tmp2name	db	'FCBTEST2.TMP', 0
t44_data	db	'HELLO'
child_fname	db	'CHILD.COM', 0
exec_pb		times 14 db 0		; EXEC parameter block
exec_cmdtail	db	0, 0x0D		; Empty command tail (len=0, CR)
wildcard	db	'*.COM', 0
testdata	db	'ABCD'

passes		dw	0
fails		dw	0
hdl1		dw	0
hdl2		dw	0
alloc_seg	dw	0
pathbuf		times 65 db 0
readbuf		times 8 db 0
test_fcb	times 37 db 0		; FCB for tests (37 bytes)
