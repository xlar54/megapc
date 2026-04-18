; SYSINFO.COM — tests INT 21h DOS services
; Displays system information using various INT 21h calls
	cpu	8086
	org	0x0100

	push	cs
	pop	ds
	push	cs
	pop	es

	; === DOS Version (AH=30h) ===
	mov	si, msg_ver
	call	print_str
	mov	ah, 0x30
	int	0x21
	push	ax
	xor	ah, ah		; AL = major
	call	print_dec
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	pop	ax
	mov	al, ah		; AH = minor
	xor	ah, ah
	call	print_dec
	call	newline

	; === Machine Type (F000:FFFE) ===
	mov	si, msg_machine
	call	print_str
	push	es
	mov	ax, 0xFFFF
	mov	es, ax
	mov	al, [es:0x0E]		; FFFF:000E = F000:FFFE
	pop	es
	cmp	al, 0xFF
	je	.mach_pc
	cmp	al, 0xFE
	je	.mach_xt
	cmp	al, 0xFD
	je	.mach_pcjr
	cmp	al, 0xFC
	je	.mach_at
	cmp	al, 0xFB
	je	.mach_xt286
	cmp	al, 0xFA
	je	.mach_ps2_30
	cmp	al, 0xF9
	je	.mach_pc_conv
	cmp	al, 0xF8
	je	.mach_ps2_80
	; Unknown
	push	ax
	mov	si, msg_mach_unk
	call	print_str
	pop	ax
	xor	ah, ah
	call	print_hex
	jmp	.mach_done
.mach_pc:
	mov	si, msg_mach_pc
	call	print_str
	jmp	.mach_done
.mach_xt:
	mov	si, msg_mach_xt
	call	print_str
	jmp	.mach_done
.mach_pcjr:
	mov	si, msg_mach_pcjr
	call	print_str
	jmp	.mach_done
.mach_at:
	mov	si, msg_mach_at
	call	print_str
	jmp	.mach_done
.mach_xt286:
	mov	si, msg_mach_xt286
	call	print_str
	jmp	.mach_done
.mach_ps2_30:
	mov	si, msg_mach_ps2
	call	print_str
	jmp	.mach_done
.mach_pc_conv:
	mov	si, msg_mach_conv
	call	print_str
	jmp	.mach_done
.mach_ps2_80:
	mov	si, msg_mach_ps2_80
	call	print_str
.mach_done:
	call	newline

	; === Current Drive (AH=19h) ===
	mov	si, msg_drive
	call	print_str
	mov	ah, 0x19
	int	0x21
	add	al, 'A'
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	call	newline

	; === Current Directory (AH=47h) ===
	mov	si, msg_curdir
	call	print_str
	mov	dl, '\'
	mov	ah, 0x02
	int	0x21
	mov	ah, 0x47
	xor	dl, dl		; Default drive
	mov	si, pathbuf
	int	0x21
	jc	.no_dir
	mov	si, pathbuf
	call	print_str
.no_dir:
	call	newline

	; === Date (AH=2Ah) ===
	mov	si, msg_date
	call	print_str
	mov	ah, 0x2A
	int	0x21
	; DH=month, DL=day, CX=year
	push	cx
	push	dx
	mov	al, dh
	xor	ah, ah
	call	print_dec
	mov	dl, '/'
	mov	ah, 0x02
	int	0x21
	pop	dx
	push	dx
	mov	al, dl
	xor	ah, ah
	call	print_dec
	mov	dl, '/'
	mov	ah, 0x02
	int	0x21
	pop	dx
	pop	cx
	mov	ax, cx
	call	print_dec
	call	newline

	; === Time (AH=2Ch) ===
	mov	si, msg_time
	call	print_str
	mov	ah, 0x2C
	int	0x21
	; CH=hour, CL=min, DH=sec
	push	dx
	mov	al, ch
	xor	ah, ah
	call	print_dec
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	mov	al, cl
	xor	ah, ah
	call	print_dec_pad2
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	pop	dx
	mov	al, dh
	xor	ah, ah
	call	print_dec_pad2
	call	newline

	; === Disk Free Space (AH=36h) ===
	mov	si, msg_disk
	call	print_str
	mov	ah, 0x36
	mov	dl, 0		; Default drive
	int	0x21
	; AX=secs/cluster, BX=free clusters, CX=bytes/sector, DX=total clusters
	push	ax
	push	bx
	push	cx
	push	dx
	; Free bytes = BX * AX * CX
	pop	dx		; total clusters
	pop	cx		; bytes/sector
	pop	bx		; free clusters
	pop	ax		; secs/cluster
	push	dx
	push	cx
	push	ax
	; Print free clusters
	mov	ax, bx
	call	print_dec
	mov	si, msg_free_cl
	call	print_str
	; Print total clusters
	pop	ax		; secs/cluster
	pop	cx		; bytes/sector
	pop	dx		; total clusters
	push	ax
	push	cx
	mov	ax, dx
	call	print_dec
	mov	si, msg_total_cl
	call	print_str
	; Print bytes/sector
	pop	ax		; bytes/sector
	call	print_dec
	mov	si, msg_bps
	call	print_str
	; Print secs/cluster
	pop	ax		; secs/cluster
	call	print_dec
	mov	si, msg_spc
	call	print_str
	call	newline

	; === IOCTL stdout (AH=44h AL=00) ===
	mov	si, msg_ioctl
	call	print_str
	mov	ax, 0x4400
	mov	bx, 1		; stdout
	int	0x21
	jc	.ioctl_err
	; DX = device info
	mov	ax, dx
	call	print_hex
	test	dx, 0x0080	; ISDEV bit
	jz	.ioctl_file
	mov	si, msg_dev
	call	print_str
	jmp	.ioctl_done
.ioctl_file:
	mov	si, msg_file
	call	print_str
	jmp	.ioctl_done
.ioctl_err:
	mov	si, msg_err
	call	print_str
.ioctl_done:
	call	newline

	; === DTA (AH=2Fh) ===
	mov	si, msg_dta
	call	print_str
	mov	ah, 0x2F
	int	0x21
	; ES:BX = DTA
	mov	ax, es
	call	print_hex
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	mov	ax, bx
	call	print_hex
	call	newline

	; === PSP Segment (AH=62h) ===
	mov	si, msg_psp
	call	print_str
	mov	ah, 0x62
	int	0x21
	; BX = PSP segment
	mov	ax, bx
	call	print_hex
	call	newline

	; === Command Tail (PSP:80h) ===
	mov	si, msg_tail
	call	print_str
	; Read from our own PSP
	mov	ah, 0x62
	int	0x21
	mov	es, bx
	mov	al, [es:0x80]	; Length
	xor	ah, ah
	push	ax
	mov	dl, '['
	mov	ah, 0x02
	int	0x21
	pop	ax
	push	ax
	call	print_dec
	mov	dl, ']'
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	; Print the tail bytes
	pop	cx
	jcxz	.no_tail
	mov	si, 0x81
.print_tail:
	mov	dl, [es:si]
	cmp	dl, 0x0D
	je	.no_tail
	mov	ah, 0x02
	int	0x21
	inc	si
	dec	cx
	jnz	.print_tail
.no_tail:
	call	newline

	; === Break Flag (AH=33h) ===
	mov	si, msg_break
	call	print_str
	mov	ax, 0x3300
	int	0x21
	mov	al, dl
	xor	ah, ah
	call	print_dec
	call	newline

	; === Verify Flag (AH=54h) ===
	mov	si, msg_verify
	call	print_str
	mov	ah, 0x54
	int	0x21
	xor	ah, ah
	call	print_dec
	call	newline

	; === Environment (walk env block) ===
	mov	si, msg_env
	call	print_str
	call	newline
	mov	ah, 0x62
	int	0x21
	mov	es, bx			; ES = PSP
	mov	es, [es:0x2C]		; ES = env segment
	xor	si, si
.env_loop:
	cmp	byte [es:si], 0		; Double null = end
	je	.env_done
	; Print this string
.env_print:
	mov	dl, [es:si]
	or	dl, dl
	jz	.env_next
	mov	ah, 0x02
	int	0x21
	inc	si
	jmp	.env_print
.env_next:
	inc	si			; Skip null
	call	newline
	jmp	.env_loop
.env_done:
	call	newline

	; === FCB Open (AH=0Fh) ===
	mov	si, msg_fcb_open
	call	print_str
	; Build FCB for SHELL.COM
	mov	di, fcb_test
	xor	al, al
	mov	cx, 37
	rep	stosb
	mov	byte [fcb_test+0], 0	; Default drive
	mov	byte [fcb_test+1], 'S'
	mov	byte [fcb_test+2], 'H'
	mov	byte [fcb_test+3], 'E'
	mov	byte [fcb_test+4], 'L'
	mov	byte [fcb_test+5], 'L'
	mov	byte [fcb_test+6], ' '
	mov	byte [fcb_test+7], ' '
	mov	byte [fcb_test+8], ' '
	mov	byte [fcb_test+9], 'C'
	mov	byte [fcb_test+10], 'O'
	mov	byte [fcb_test+11], 'M'
	mov	dx, fcb_test
	mov	ah, 0x0F
	int	0x21
	cmp	al, 0
	jne	.fcb_fail
	; Print file size from FCB+10h
	mov	ax, [fcb_test+0x10]
	call	print_dec
	mov	si, msg_bytes
	call	print_str
	jmp	.fcb_done
.fcb_fail:
	mov	si, msg_err
	call	print_str
.fcb_done:
	call	newline

	; === FCB Find First (AH=11h) ===
	mov	si, msg_fcb_find
	call	print_str
	; Set up FCB with ??????????? (all wildcards)
	mov	di, fcb_test
	mov	byte [fcb_test+0], 0	; Default drive
	mov	cx, 11
	mov	al, '?'
	inc	di
	rep	stosb
	mov	dx, fcb_test
	mov	ah, 0x11
	int	0x21
	cmp	al, 0
	jne	.fcb_find_fail
	; Print first found name from DTA+1 (8.3 format)
	; DTA is at PSP:0080, but we set it... just read from 0080
	mov	si, 0x81		; DTA+1 = filename
	mov	cx, 8
.fcb_find_name:
	lodsb
	cmp	al, ' '
	je	.fcb_find_dot
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.fcb_find_name
.fcb_find_dot:
	mov	si, 0x89		; DTA+9 = extension
	cmp	byte [si], ' '
	je	.fcb_find_end
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	mov	cx, 3
.fcb_find_ext:
	lodsb
	cmp	al, ' '
	je	.fcb_find_end
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.fcb_find_ext
.fcb_find_end:
	jmp	.fcb_find_done
.fcb_find_fail:
	mov	si, msg_err
	call	print_str
.fcb_find_done:
	call	newline

	; === Alloc Strategy (AH=58h) ===
	mov	si, msg_alloc
	call	print_str
	mov	ax, 0x5800
	int	0x21
	call	print_dec
	call	newline

	; === Return Code (AH=4Dh) ===
	mov	si, msg_retcode
	call	print_str
	mov	ah, 0x4D
	int	0x21
	call	print_dec
	call	newline

	; Done
	mov	ax, 0x4C00
	int	0x21

; --- Subroutines ---

print_str:
	push	ax
.ps_loop:
	lodsb
	or	al, al
	jz	.ps_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.ps_loop
.ps_done:
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

; Print AX as unsigned decimal
print_dec:
	push	ax
	push	bx
	push	cx
	push	dx
	xor	cx, cx
	mov	bx, 10
.pd_div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_div
.pd_print:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pd_print
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; Print AL as 2-digit decimal with leading zero
print_dec_pad2:
	push	ax
	push	dx
	cmp	al, 10
	jae	.pd2_no_pad
	push	ax
	mov	dl, '0'
	mov	ah, 0x02
	int	0x21
	pop	ax
.pd2_no_pad:
	call	print_dec
	pop	dx
	pop	ax
	ret

; Print AX as 4-digit hex
print_hex:
	push	ax
	push	cx
	push	dx
	mov	cx, 4
.ph_loop:
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.ph_ok
	add	al, 7
.ph_ok:
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph_loop
	pop	dx
	pop	cx
	pop	ax
	ret

; --- Data ---
msg_retcode	db	'Last Return: ', 0
msg_ver		db	'DOS Version: ', 0
msg_drive	db	'Current Drive: ', 0
msg_curdir	db	'Current Dir: ', 0
msg_date	db	'Date: ', 0
msg_time	db	'Time: ', 0
msg_disk	db	'Disk: ', 0
msg_free_cl	db	' free / ', 0
msg_total_cl	db	' total clusters, ', 0
msg_bps		db	' bytes/sec, ', 0
msg_spc		db	' secs/clust', 0
msg_ioctl	db	'IOCTL stdout: ', 0
msg_dev		db	' (device)', 0
msg_file	db	' (file)', 0
msg_err		db	' (error)', 0
msg_dta		db	'DTA: ', 0
msg_psp		db	'PSP Segment: ', 0
msg_tail	db	'Cmd Tail: ', 0
msg_break	db	'Break Flag: ', 0
msg_verify	db	'Verify Flag: ', 0
msg_machine	db	'Machine: ', 0
msg_mach_pc	db	'IBM PC (FF)', 0
msg_mach_xt	db	'IBM PC/XT (FE)', 0
msg_mach_pcjr	db	'IBM PCjr (FD)', 0
msg_mach_at	db	'IBM PC/AT (FC)', 0
msg_mach_xt286	db	'IBM PC/XT-286 (FB)', 0
msg_mach_ps2	db	'IBM PS/2 Model 30 (FA)', 0
msg_mach_conv	db	'IBM PC Convertible (F9)', 0
msg_mach_ps2_80	db	'IBM PS/2 Model 80 (F8)', 0
msg_mach_unk	db	'Unknown: ', 0
msg_env		db	'Environment:', 0
msg_fcb_open	db	'FCB Open SHELL.COM: ', 0
msg_fcb_find	db	'FCB FindFirst *.*: ', 0
msg_bytes	db	' bytes', 0
msg_alloc	db	'Alloc Strategy: ', 0

pathbuf		times 65 db 0
fcb_test	times 37 db 0
