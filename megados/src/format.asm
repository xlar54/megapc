; FORMAT.COM — Format a floppy disk for MegaDOS
; Usage: FORMAT drive: [/S] [/V:label] [/Q]
;   /S = copy system files (make bootable)
;   /V:label = set volume label
;   /Q = quick format (skip verify)
; Detects disk geometry via INT 13h AH=08h — works with any floppy format.
	cpu	8086
	org	0x0100

start:
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	; Parse command line
	mov	si, 0x0081
	call	skip_sp

	; Get drive letter
	mov	al, [si]
	cmp	al, 0x0D
	je	usage
	cmp	al, 0
	je	usage
	or	al, 0x20
	cmp	al, 'a'
	jb	usage
	cmp	al, 'z'
	ja	usage
	sub	al, 'a'
	mov	[drive], al
	inc	si
	cmp	byte [si], ':'
	jne	usage
	inc	si

	; Parse switches
	mov	byte [opt_sys], 0
	mov	byte [opt_quick], 0
	mov	byte [vol_label], 0

.parse_switch:
	call	skip_sp
	cmp	byte [si], 0x0D
	je	.parse_done
	cmp	byte [si], 0
	je	.parse_done
	cmp	byte [si], '/'
	jne	usage
	inc	si
	mov	al, [si]
	or	al, 0x20
	cmp	al, 's'
	je	.sw_sys
	cmp	al, 'q'
	je	.sw_quick
	cmp	al, 'v'
	je	.sw_vol
	jmp	usage

.sw_sys:
	mov	byte [opt_sys], 1
	inc	si
	jmp	.parse_switch
.sw_quick:
	mov	byte [opt_quick], 1
	inc	si
	jmp	.parse_switch
.sw_vol:
	inc	si
	cmp	byte [si], ':'
	jne	usage
	inc	si
	mov	di, vol_label
	mov	cx, 11
.copy_vol:
	mov	al, [si]
	cmp	al, 0x0D
	je	.vol_done
	cmp	al, 0
	je	.vol_done
	cmp	al, ' '
	je	.vol_done
	cmp	al, '/'
	je	.vol_done
	cmp	al, 'a'
	jb	.vol_store
	cmp	al, 'z'
	ja	.vol_store
	sub	al, 0x20
.vol_store:
	stosb
	inc	si
	dec	cx
	jnz	.copy_vol
.vol_done:
	; Pad with spaces
	mov	al, ' '
	rep	stosb
	jmp	.parse_switch

.parse_done:
	; ============================================================
	; Detect disk geometry via INT 13h AH=08h
	; ============================================================
	mov	ah, 0x08
	mov	dl, [drive]
	int	0x13
	jc	.detect_err

	; CL bits 0-5 = max sector, CH = max cylinder, DH = max head, BL = type
	mov	al, cl
	and	al, 0x3F
	mov	[geo_spt], al		; Sectors per track
	mov	al, ch
	inc	al
	mov	[geo_cyls], al		; Cylinders (max+1)
	mov	al, dh
	inc	al
	mov	[geo_heads], al		; Heads (max+1)
	mov	[geo_type], bl		; BIOS drive type

	; Look up format parameters from geometry
	; Total sectors = cyls * heads * spt
	xor	ah, ah
	mov	al, [geo_cyls]
	mul	byte [geo_heads]	; AX = cyls * heads
	xor	dh, dh
	mov	dl, [geo_spt]
	mul	dx			; DX:AX = total sectors (fits in AX for floppies)
	mov	[bpb_totsec], ax

	; SPT and heads
	xor	ah, ah
	mov	al, [geo_spt]
	mov	[bpb_spt], ax
	mov	al, [geo_heads]
	mov	[bpb_heads], ax

	; Determine format-specific BPB values from total sectors
	; 320  = 160K  (40*1*8)  → SPC=1, SPF=1, root=64,  media=FE
	; 360  = 180K  (40*1*9)  → SPC=1, SPF=2, root=64,  media=FC
	; 640  = 320K  (40*2*8)  → SPC=2, SPF=1, root=112, media=FF
	; 720  = 360K  (40*2*9)  → SPC=2, SPF=2, root=112, media=FD
	; 1440 = 720K  (80*2*9)  → SPC=2, SPF=3, root=112, media=F9
	; 2400 = 1.2MB (80*2*15) → SPC=1, SPF=7, root=224, media=F9
	; 2880 = 1.44MB(80*2*18) → SPC=1, SPF=9, root=224, media=F0
	mov	ax, [bpb_totsec]
	cmp	ax, 320
	je	.fmt_160k
	cmp	ax, 360
	je	.fmt_180k
	cmp	ax, 640
	je	.fmt_320k
	cmp	ax, 720
	je	.fmt_360k
	cmp	ax, 1440
	je	.fmt_720k
	cmp	ax, 2400
	je	.fmt_1200k
	cmp	ax, 2880
	je	.fmt_1440k
	; Unknown — default to 360K-like
	jmp	.fmt_360k

.fmt_160k:
	mov	byte [bpb_spc], 1
	mov	word [bpb_spf], 1
	mov	word [bpb_rootents], 64
	mov	byte [bpb_media], 0xFE
	jmp	.fmt_detected

.fmt_180k:
	mov	byte [bpb_spc], 1
	mov	word [bpb_spf], 2
	mov	word [bpb_rootents], 64
	mov	byte [bpb_media], 0xFC
	jmp	.fmt_detected

.fmt_320k:
	mov	byte [bpb_spc], 2
	mov	word [bpb_spf], 1
	mov	word [bpb_rootents], 112
	mov	byte [bpb_media], 0xFF
	jmp	.fmt_detected

.fmt_360k:
	mov	byte [bpb_spc], 2
	mov	word [bpb_spf], 2
	mov	word [bpb_rootents], 112
	mov	byte [bpb_media], 0xFD
	jmp	.fmt_detected

.fmt_720k:
	mov	byte [bpb_spc], 2
	mov	word [bpb_spf], 3
	mov	word [bpb_rootents], 112
	mov	byte [bpb_media], 0xF9
	jmp	.fmt_detected

.fmt_1200k:
	mov	byte [bpb_spc], 1
	mov	word [bpb_spf], 7
	mov	word [bpb_rootents], 224
	mov	byte [bpb_media], 0xF9
	jmp	.fmt_detected

.fmt_1440k:
	mov	byte [bpb_spc], 1
	mov	word [bpb_spf], 9
	mov	word [bpb_rootents], 224
	mov	byte [bpb_media], 0xF0
	; fall through

.fmt_detected:
	; Compute derived values
	mov	word [bpb_bps], 512
	mov	word [bpb_reserved], 1
	mov	byte [bpb_nfats], 2

	; root_dir_sec = reserved + nfats * spf
	mov	ax, [bpb_spf]
	shl	ax, 1			; * 2 FATs
	inc	ax			; + 1 reserved
	mov	[root_dir_sec], ax

	; root_dir_secs = (rootents * 32) / 512
	mov	ax, [bpb_rootents]
	mov	cl, 5
	shl	ax, cl			; * 32
	mov	cl, 9
	shr	ax, cl			; / 512
	mov	[root_dir_secs], ax

	; data_start = root_dir_sec + root_dir_secs
	mov	ax, [root_dir_sec]
	add	ax, [root_dir_secs]
	mov	[data_start], ax

	; bytes_per_cluster
	xor	ah, ah
	mov	al, [bpb_spc]
	mov	cl, 9
	shl	ax, cl			; * 512
	mov	[bytes_per_clust], ax

	jmp	.confirm

.detect_err:
	mov	si, msg_no_disk
	call	pstr
	jmp	exit

.confirm:
	; Print warning
	mov	si, msg_warn1
	call	pstr
	mov	al, [drive]
	add	al, 'A'
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	si, msg_warn2
	call	pstr

	; Wait for Y/N
	mov	ah, 0x08
	int	0x21
	or	al, 0x20
	cmp	al, 'y'
	je	.confirmed
	mov	si, msg_abort
	call	pstr
	jmp	exit

.confirmed:
	call	crlf

	; === Format the disk ===
	mov	si, msg_formatting
	call	pstr

	mov	bx, sector_buf

	; Step 1: Write boot sector
	mov	si, msg_boot
	call	pstr
	call	build_boot_sector
	mov	ax, 0
	call	write_sector
	jc	disk_err

	; Step 2: Write FATs
	mov	si, msg_fat
	call	pstr
	; Clear sector buffer
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	; First FAT sector has media byte
	mov	al, [bpb_media]
	mov	[sector_buf], al
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF
	; Write first sector of FAT1
	mov	bx, sector_buf
	mov	ax, 1			; LBA 1
	call	write_sector
	jc	disk_err
	; Clear and write remaining FAT1 sectors
	mov	byte [sector_buf], 0
	mov	byte [sector_buf+1], 0
	mov	byte [sector_buf+2], 0
	mov	cx, [bpb_spf]
	dec	cx			; Already wrote first sector
	mov	ax, 2			; LBA 2
.write_fat1:
	jcxz	.fat1_done
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	inc	ax
	dec	cx
	jmp	.write_fat1
.fat1_done:
	; Write FAT2 (same pattern)
	mov	al, [bpb_media]
	mov	[sector_buf], al
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF
	; FAT2 starts at reserved + spf
	mov	ax, [bpb_spf]
	inc	ax			; + 1 reserved
	push	ax
	call	write_sector
	jc	disk_err
	pop	ax
	inc	ax
	mov	byte [sector_buf], 0
	mov	byte [sector_buf+1], 0
	mov	byte [sector_buf+2], 0
	mov	cx, [bpb_spf]
	dec	cx
.write_fat2:
	jcxz	.fat2_done
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	inc	ax
	dec	cx
	jmp	.write_fat2
.fat2_done:

	; Step 3: Write empty root directory
	mov	si, msg_rootdir
	call	pstr
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	mov	ax, [root_dir_sec]
	mov	cx, [root_dir_secs]
.write_rootdir:
	push	cx
	push	ax
	mov	bx, sector_buf
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	inc	ax
	dec	cx
	jnz	.write_rootdir

	; Step 4: Volume label
	cmp	byte [vol_label], 0
	je	.no_vol
	mov	si, msg_label
	call	pstr
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	mov	si, vol_label
	mov	di, sector_buf
	mov	cx, 11
	rep	movsb
	mov	byte [sector_buf+11], 0x08
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	call	write_sector
	jc	disk_err
.no_vol:

	; Step 5: Verify (unless /Q)
	cmp	byte [opt_quick], 1
	je	.skip_verify
	mov	si, msg_verify
	call	pstr
	xor	ax, ax
	mov	cx, [bpb_totsec]
.verify_loop:
	push	cx
	push	ax
	call	read_sector
	pop	ax
	pop	cx
	jc	.verify_err
	inc	ax
	dec	cx
	jnz	.verify_loop
	jmp	.verify_ok
.verify_err:
	mov	si, msg_bad_sec
	call	pstr
.verify_ok:
.skip_verify:

	; Step 6: System files (if /S)
	cmp	byte [opt_sys], 1
	je	do_sys
after_sys:

	; Done
	call	crlf
	mov	si, msg_done
	call	pstr
	; Print KB free = (total_secs - data_start) * 512 / 1024
	mov	ax, [bpb_totsec]
	sub	ax, [data_start]
	shr	ax, 1			; * 512 / 1024 = / 2
	call	pdec
	mov	si, msg_kfree
	call	pstr

exit:
	mov	ax, 0x4C00
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

disk_err:
	mov	si, msg_disk_err
	call	pstr
	mov	ax, 0x4C02
	int	0x21

; ============================================================================
; System file copy (/S)
; ============================================================================
do_sys:
	mov	si, msg_sys
	call	pstr

	; Open SHELL.COM from current drive
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, shell_fname
	int	0x21
	jc	.sys_err
	mov	[sys_handle], ax

	; Get file size
	mov	bx, ax
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	mov	[sys_size], ax
	mov	[sys_size+2], dx
	; Seek back to start
	mov	ax, 0x4200
	xor	cx, cx
	xor	dx, dx
	mov	bx, [sys_handle]
	int	0x21

	; Read file and write to data area, cluster by cluster
	mov	word [cur_cluster], 2
	mov	ax, [data_start]
	mov	[cur_lba], ax

.sys_read_loop:
	mov	ah, 0x3F
	mov	bx, [sys_handle]
	mov	cx, [bytes_per_clust]
	mov	dx, sector_buf
	int	0x21
	jc	.sys_err
	cmp	ax, 0
	je	.sys_read_done
	mov	[.sys_bytes_read], ax

	; Write sectors of this cluster
	push	ax
	xor	ch, ch
	mov	cl, [bpb_spc]
	mov	bx, sector_buf
	mov	ax, [cur_lba]
.sys_write_secs:
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sys_write_secs
	mov	ax, [cur_lba]
	xor	ch, ch
	mov	cl, [bpb_spc]
	add	ax, cx
	mov	[cur_lba], ax
	pop	ax

	; Track cluster
	inc	word [cur_cluster]

	; More data?
	mov	ax, [.sys_bytes_read]
	cmp	ax, [bytes_per_clust]
	je	.sys_read_loop

.sys_read_done:
	mov	ah, 0x3E
	mov	bx, [sys_handle]
	int	0x21

	; Build FAT with cluster chain in sector_buf
	; Need enough space for all FAT sectors
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	mov	ax, [bpb_spf]
	mov	bx, 256
	mul	bx			; AX = spf * 256 words
	mov	cx, ax
	xor	ax, ax
	rep	stosw
	mov	al, [bpb_media]
	mov	[sector_buf], al
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF

	; Write chain: 2→3→4→...→EOF
	mov	ax, 2
	mov	cx, [cur_cluster]
	sub	cx, 2
	dec	cx
.sys_fat_chain:
	jcxz	.sys_fat_eof
	push	cx
	mov	bx, ax
	inc	bx
	call	fat12_write
	pop	cx
	inc	ax
	dec	cx
	jmp	.sys_fat_chain
.sys_fat_eof:
	mov	bx, 0xFFF
	call	fat12_write

	; Write FAT1 (all sectors)
	mov	bx, sector_buf
	mov	ax, 1			; FAT1 starts at LBA 1
	mov	cx, [bpb_spf]
.sys_wf1:
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sys_wf1
	; Write FAT2
	mov	bx, sector_buf
	mov	ax, [bpb_spf]
	inc	ax			; FAT2 start = reserved + spf
	mov	cx, [bpb_spf]
.sys_wf2:
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sys_wf2

	; Write root dir entry for SHELL.COM
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	mov	di, sector_buf
	cmp	byte [vol_label], 0
	je	.sys_no_vol
	mov	si, vol_label
	mov	cx, 11
	rep	movsb
	mov	byte [sector_buf+11], 0x08
	add	di, 32 - 11		; DI already advanced 11 by movsb
.sys_no_vol:
	mov	byte [di+0], 'C'
	mov	byte [di+1], 'O'
	mov	byte [di+2], 'M'
	mov	byte [di+3], 'M'
	mov	byte [di+4], 'A'
	mov	byte [di+5], 'N'
	mov	byte [di+6], 'D'
	mov	byte [di+7], ' '
	mov	byte [di+8], 'C'
	mov	byte [di+9], 'O'
	mov	byte [di+10], 'M'
	mov	byte [di+11], 0x20
	mov	word [di+26], 2
	mov	ax, [sys_size]
	mov	[di+28], ax
	mov	ax, [sys_size+2]
	mov	[di+30], ax
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	call	write_sector
	jc	disk_err

	jmp	after_sys

.sys_err:
	mov	si, msg_sys_err
	call	pstr
	jmp	after_sys

.sys_bytes_read: dw	0

; ============================================================================
; FAT12 write — value BX into FAT entry AX (operates on sector_buf)
; ============================================================================
fat12_write:
	push	cx
	push	dx
	push	si
	mov	si, ax
	mov	cx, ax
	shr	si, 1
	add	si, cx
	mov	dx, [sector_buf + si]
	test	cx, 1
	jnz	.fat_odd
	and	dx, 0xF000
	or	dx, bx
	jmp	.fat_store
.fat_odd:
	and	dx, 0x000F
	push	cx
	mov	cl, 4
	shl	bx, cl
	pop	cx
	or	dx, bx
.fat_store:
	mov	[sector_buf + si], dx
	pop	si
	pop	dx
	pop	cx
	ret

; ============================================================================
; Build boot sector in sector_buf — uses BPB variables
; ============================================================================
build_boot_sector:
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	; Jump + NOP
	mov	byte [sector_buf], 0xEB
	mov	byte [sector_buf+1], 0x3C
	mov	byte [sector_buf+2], 0x90
	; OEM name
	mov	di, sector_buf + 3
	mov	si, oem_name
	mov	cx, 8
	rep	movsb
	; BPB from variables
	mov	ax, [bpb_bps]
	mov	[sector_buf+11], ax
	mov	al, [bpb_spc]
	mov	[sector_buf+13], al
	mov	ax, [bpb_reserved]
	mov	[sector_buf+14], ax
	mov	al, [bpb_nfats]
	mov	[sector_buf+16], al
	mov	ax, [bpb_rootents]
	mov	[sector_buf+17], ax
	mov	ax, [bpb_totsec]
	mov	[sector_buf+19], ax
	mov	al, [bpb_media]
	mov	[sector_buf+21], al
	mov	ax, [bpb_spf]
	mov	[sector_buf+22], ax
	mov	ax, [bpb_spt]
	mov	[sector_buf+24], ax
	mov	ax, [bpb_heads]
	mov	[sector_buf+26], ax
	; Boot signature
	mov	byte [sector_buf+510], 0x55
	mov	byte [sector_buf+511], 0xAA
	; If /S, copy boot code from drive A
	cmp	byte [opt_sys], 1
	jne	.boot_no_sys
	push	bx
	push	ax
	mov	bx, sector_buf + 512
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, 0		; Drive A
	int	0x13
	jc	.boot_no_copy
	; Copy boot code (after BPB) from drive A
	mov	si, sector_buf + 512 + 0x3E
	mov	di, sector_buf + 0x3E
	mov	cx, 0x1FE - 0x3E
	rep	movsb
.boot_no_copy:
	pop	ax
	pop	bx
.boot_no_sys:
	ret

; ============================================================================
; Disk I/O
; ============================================================================
write_sector:
	push	ax
	push	bx
	push	cx
	push	dx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

read_sector:
	push	ax
	push	bx
	push	cx
	push	dx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; LBA in AX → CHS — uses BPB variables
lba_to_chs:
	push	bx
	push	ax
	mov	ax, [bpb_spt]
	mul	word [bpb_heads]
	mov	bx, ax
	pop	ax
	push	ax
	xor	dx, dx
	div	bx
	mov	ch, al		; Cylinder
	mov	ax, dx
	xor	dx, dx
	div	word [bpb_spt]
	mov	dh, al		; Head
	mov	cl, dl
	inc	cl		; Sector (1-based)
	pop	ax
	pop	bx
	ret

; ============================================================================
; Helpers
; ============================================================================
skip_sp:
	cmp	byte [si], ' '
	jne	.done
	inc	si
	jmp	skip_sp
.done:
	ret

pstr:
	lodsb
	or	al, al
	jz	.done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	pstr
.done:
	ret

crlf:
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
.div:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.div
.pr:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.pr
	pop	bx
	pop	dx
	pop	cx
	ret

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: FORMAT drive: [/S] [/V:label] [/Q]', 0x0D, 0x0A, 0
msg_warn1	db	'WARNING: All data on drive ', 0
msg_warn2	db	': will be destroyed!', 0x0D, 0x0A
		db	'Proceed (Y/N)? ', 0
msg_abort	db	0x0D, 0x0A, 'Format aborted.', 0x0D, 0x0A, 0
msg_formatting	db	'Formatting...', 0x0D, 0x0A, 0
msg_boot	db	'  Writing boot sector', 0x0D, 0x0A, 0
msg_fat		db	'  Writing FAT', 0x0D, 0x0A, 0
msg_rootdir	db	'  Writing root directory', 0x0D, 0x0A, 0
msg_label	db	'  Writing volume label', 0x0D, 0x0A, 0
msg_verify	db	'  Verifying...', 0x0D, 0x0A, 0
msg_bad_sec	db	'  Warning: bad sector found', 0x0D, 0x0A, 0
msg_sys		db	'  Copying system files', 0x0D, 0x0A, 0
msg_sys_err	db	'  Cannot copy system files', 0x0D, 0x0A, 0
msg_done	db	'Format complete.', 0x0D, 0x0A, 0
msg_kfree	db	'KB available on disk', 0x0D, 0x0A, 0
msg_disk_err	db	'Disk error during format.', 0x0D, 0x0A, 0
msg_no_disk	db	'Drive not ready', 0x0D, 0x0A, 0

oem_name	db	'MEGADOS '
shell_fname	db	'COMMAND.COM', 0

; ============================================================================
; Data
; ============================================================================
drive		db	0
opt_sys		db	0
opt_quick	db	0
vol_label	times 11 db 0

; Detected geometry
geo_spt		db	0
geo_cyls	db	0
geo_heads	db	0
geo_type	db	0

; BPB variables
bpb_bps		dw	512
bpb_spc		db	0
bpb_reserved	dw	1
bpb_nfats	db	2
bpb_rootents	dw	0
bpb_totsec	dw	0
bpb_media	db	0
bpb_spf		dw	0
bpb_spt		dw	0
bpb_heads	dw	0

; Derived
root_dir_sec	dw	0
root_dir_secs	dw	0
data_start	dw	0
bytes_per_clust	dw	0

; System file copy state
sys_handle	dw	0
sys_size	dd	0
cur_cluster	dw	0
cur_lba		dw	0

; Sector buffer — must be large enough for FAT write (up to 9*512 = 4608)
sector_buf:
