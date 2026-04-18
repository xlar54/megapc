; FORMAT.COM — Format a floppy disk for MegaDOS
; Usage: FORMAT drive: [/S] [/V:label] [/Q]
;   /S = copy system files (make bootable)
;   /V:label = set volume label
;   /Q = quick format (skip verify)
	cpu	8086
	org	0x0100

; Disk geometry (360K)
BYTES_PER_SEC	equ	512
SECS_PER_CLUST	equ	2
RESERVED_SECS	equ	1
NUM_FATS	equ	2
SECS_PER_FAT	equ	2
ROOT_ENTRIES	equ	112
TOTAL_SECS	equ	720
SPT		equ	9
HEADS		equ	2
MEDIA_BYTE	equ	0xFD
ROOT_DIR_SEC	equ	5	; First root dir sector
ROOT_DIR_SECS	equ	7	; Root dir sectors
DATA_START_SEC	equ	12	; First data sector

start:
	push	cs
	pop	ds
	push	cs
	pop	es

	; Parse command line
	mov	si, 0x0081
	call	skip_sp

	; Get drive letter
	mov	al, [si]
	cmp	al, 0x0D
	je	usage
	cmp	al, 0
	je	usage
	; Uppercase
	cmp	al, 'a'
	jb	.drv_ok
	cmp	al, 'z'
	ja	.drv_ok
	sub	al, 0x20
.drv_ok:
	cmp	al, 'A'
	jb	usage
	cmp	al, 'B'
	ja	usage
	sub	al, 'A'
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
	cmp	al, 'a'
	jb	.sw_upper
	cmp	al, 'z'
	ja	.sw_upper
	sub	al, 0x20
.sw_upper:
	cmp	al, 'S'
	je	.sw_sys
	cmp	al, 'Q'
	je	.sw_quick
	cmp	al, 'V'
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
	; Copy volume label (up to 11 chars)
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
	; Uppercase
	cmp	al, 'a'
	jb	.vol_store
	cmp	al, 'z'
	ja	.vol_store
	sub	al, 0x20
.vol_store:
	mov	[di], al
	inc	di
	inc	si
	dec	cx
	jnz	.copy_vol
.vol_done:
	; Pad with spaces
	jcxz	.vol_padded
.vol_pad:
	mov	byte [di], ' '
	inc	di
	dec	cx
	jnz	.vol_pad
.vol_padded:
	jmp	.parse_switch

.parse_done:
	; Confirm
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
	cmp	al, 'Y'
	je	.confirmed
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

	; Use sector buffer at end of program
	mov	bx, sector_buf

	; Step 1: Write boot sector
	mov	si, msg_boot
	call	pstr
	call	build_boot_sector
	mov	ax, 0		; LBA 0
	call	write_sector
	jc	disk_err

	; Step 2: Write FATs
	mov	si, msg_fat
	call	pstr
	; Build empty FAT sector with media byte
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw		; Clear 512 bytes
	mov	byte [sector_buf], MEDIA_BYTE
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF
	; Write FAT1 sector 1
	mov	ax, 1
	call	write_sector
	jc	disk_err
	; Clear for second FAT sector
	mov	byte [sector_buf], 0
	mov	byte [sector_buf+1], 0
	mov	byte [sector_buf+2], 0
	; Write FAT1 sector 2
	mov	ax, 2
	call	write_sector
	jc	disk_err
	; Write FAT2 (copy of FAT1)
	; Rebuild first sector
	mov	byte [sector_buf], MEDIA_BYTE
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF
	mov	ax, 3
	call	write_sector
	jc	disk_err
	mov	byte [sector_buf], 0
	mov	byte [sector_buf+1], 0
	mov	byte [sector_buf+2], 0
	mov	ax, 4
	call	write_sector
	jc	disk_err

	; Step 3: Write empty root directory
	mov	si, msg_rootdir
	call	pstr
	; Clear sector buffer
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	; Write 7 root dir sectors
	mov	ax, ROOT_DIR_SEC
	mov	cx, ROOT_DIR_SECS
.write_rootdir:
	push	cx
	push	ax
	call	write_sector
	pop	ax
	pop	cx
	jc	disk_err
	inc	ax
	dec	cx
	jnz	.write_rootdir

	; Step 4: Volume label (if specified)
	cmp	byte [vol_label], 0
	je	.no_vol
	mov	si, msg_label
	call	pstr
	; Build dir entry with volume label attribute
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw		; Clear
	; Copy label to first dir entry
	mov	si, vol_label
	mov	di, sector_buf
	mov	cx, 11
	rep	movsb
	mov	byte [sector_buf+11], 0x08	; Volume label attribute
	; Write first root dir sector
	mov	ax, ROOT_DIR_SEC
	call	write_sector
	jc	disk_err
.no_vol:

	; Step 5: Verify (unless /Q)
	cmp	byte [opt_quick], 1
	je	.skip_verify
	mov	si, msg_verify
	call	pstr
	xor	ax, ax		; Start at sector 0
	mov	cx, TOTAL_SECS
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
	; Continue anyway
.verify_ok:
.skip_verify:

	; Step 6: System files (if /S)
	cmp	byte [opt_sys], 1
	je	do_sys
after_sys:

	; Done!
	call	crlf
	mov	si, msg_done
	call	pstr
	; Print bytes free
	; Free = (TOTAL_SECS - DATA_START_SEC) * 512
	mov	ax, (TOTAL_SECS - DATA_START_SEC) * BYTES_PER_SEC / 1024
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
	mov	al, 0		; Read
	mov	dx, shell_fname
	int	0x21
	jc	.sys_err
	mov	[sys_handle], ax

	; Read SHELL.COM and write to target disk
	; First, read the file size
	mov	bx, ax
	mov	ax, 0x4202	; Seek to end
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

	; Calculate clusters needed
	mov	ax, [sys_size]
	add	ax, SECS_PER_CLUST * BYTES_PER_SEC - 1
	mov	cl, 10		; / 1024 (bytes per cluster)
	shr	ax, cl
	inc	ax		; Round up
	mov	[sys_clusters], ax

	; Read file and write to data area, cluster by cluster
	mov	word [cur_cluster], 2	; First data cluster
	mov	ax, DATA_START_SEC
	mov	[cur_lba], ax
.sys_read_loop:
	; Read one cluster from file (1024 bytes = 2 sectors)
	mov	ah, 0x3F
	mov	bx, [sys_handle]
	mov	cx, SECS_PER_CLUST * BYTES_PER_SEC
	mov	dx, sector_buf
	int	0x21
	jc	.sys_err
	cmp	ax, 0
	je	.sys_read_done
	mov	[.sys_bytes_read], ax

	; Write sectors to target disk
	push	ax
	mov	ax, [cur_lba]
	call	write_sector
	jc	disk_err
	inc	word [cur_lba]
	; Write second sector of cluster
	mov	ax, [cur_lba]
	mov	bx, sector_buf + 512
	call	write_sector
	mov	bx, sector_buf		; Reset BX
	jc	disk_err
	inc	word [cur_lba]
	pop	ax

	; Update FAT chain
	mov	ax, [cur_cluster]
	inc	word [cur_cluster]

	; Check if more data
	cmp	word [.sys_bytes_read], SECS_PER_CLUST * BYTES_PER_SEC
	je	.sys_read_loop

.sys_read_done:
	; Close file
	mov	ah, 0x3E
	mov	bx, [sys_handle]
	int	0x21

	; Now write the FAT with the cluster chain
	; Build FAT in sector_buf (clear full 1024 bytes for both FAT sectors)
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 512
	rep	stosw		; Clear 1024 bytes
	mov	byte [sector_buf], MEDIA_BYTE
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF
	; Write cluster chain: 2→3→4→...→EOF
	mov	ax, 2		; First cluster
	mov	cx, [cur_cluster]
	sub	cx, 2		; Number of clusters used
	dec	cx		; Last one gets EOF
.sys_fat_chain:
	jcxz	.sys_fat_eof
	; Write next cluster (AX+1) into FAT entry AX
	push	cx
	mov	bx, ax
	inc	bx		; Next cluster number
	call	fat12_write
	pop	cx
	inc	ax
	dec	cx
	jmp	.sys_fat_chain
.sys_fat_eof:
	; Write EOF for last cluster
	mov	bx, 0xFFF
	call	fat12_write

	; Write FAT to disk (both copies)
	mov	bx, sector_buf		; fat12_write destroys BX
	mov	ax, 1
	call	write_sector
	jc	disk_err
	mov	bx, sector_buf + 512
	mov	ax, 2
	call	write_sector
	jc	disk_err
	; FAT2
	mov	bx, sector_buf
	mov	ax, 3
	call	write_sector
	jc	disk_err
	mov	bx, sector_buf + 512
	mov	ax, 4
	call	write_sector
	jc	disk_err

	; Write root dir entry for SHELL.COM
	; Clear dir sector
	mov	di, sector_buf
	xor	ax, ax
	mov	cx, 256
	rep	stosw
	; Check if volume label — if so, label is entry 0, shell is entry 1
	mov	di, sector_buf
	cmp	byte [vol_label], 0
	je	.sys_no_vol_entry
	; Write volume label entry first
	push	di
	mov	si, vol_label
	mov	cx, 11
	rep	movsb
	mov	byte [sector_buf+11], 0x08
	pop	di
	add	di, 32		; Next entry
.sys_no_vol_entry:
	; Write SHELL.COM dir entry
	mov	byte [di+0], 'S'
	mov	byte [di+1], 'H'
	mov	byte [di+2], 'E'
	mov	byte [di+3], 'L'
	mov	byte [di+4], 'L'
	mov	byte [di+5], ' '
	mov	byte [di+6], ' '
	mov	byte [di+7], ' '
	mov	byte [di+8], 'C'
	mov	byte [di+9], 'O'
	mov	byte [di+10], 'M'
	mov	byte [di+11], 0x20	; Archive attribute
	mov	word [di+26], 2		; Start cluster
	mov	ax, [sys_size]
	mov	[di+28], ax
	mov	ax, [sys_size+2]
	mov	[di+30], ax
	; Write root dir first sector
	mov	bx, sector_buf
	mov	ax, ROOT_DIR_SEC
	call	write_sector
	jc	disk_err

	jmp	after_sys

.sys_err:
	mov	si, msg_sys_err
	call	pstr
	jmp	after_sys

.sys_bytes_read: dw	0

; ============================================================================
; FAT12 write helper — write value BX into FAT entry AX
; Operates on sector_buf (1024 bytes = 2 FAT sectors)
; ============================================================================
fat12_write:
	push	cx
	push	dx
	push	si
	mov	si, ax
	shr	si, 1
	add	si, ax		; SI = byte offset (cluster * 1.5)
	mov	dx, [sector_buf + si]
	test	ax, 1
	jnz	.fat_odd
	; Even cluster: low 12 bits
	and	dx, 0xF000
	or	dx, bx
	jmp	.fat_store
.fat_odd:
	; Odd cluster: high 12 bits
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
; Build boot sector in sector_buf
; ============================================================================
build_boot_sector:
	; Clear
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
	; BPB
	mov	word [sector_buf+11], BYTES_PER_SEC
	mov	byte [sector_buf+13], SECS_PER_CLUST
	mov	word [sector_buf+14], RESERVED_SECS
	mov	byte [sector_buf+16], NUM_FATS
	mov	word [sector_buf+17], ROOT_ENTRIES
	mov	word [sector_buf+19], TOTAL_SECS
	mov	byte [sector_buf+21], MEDIA_BYTE
	mov	word [sector_buf+22], SECS_PER_FAT
	mov	word [sector_buf+24], SPT
	mov	word [sector_buf+26], HEADS
	; Boot signature
	mov	byte [sector_buf+510], 0x55
	mov	byte [sector_buf+511], 0xAA
	; If /S, we should write boot code here too
	; For now, non-bootable — just BPB
	cmp	byte [opt_sys], 1
	jne	.boot_no_sys
	; Copy boot code from current boot sector (sector 0 of drive A)
	push	bx
	push	ax
	mov	bx, sector_buf + 512	; Temp buffer
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, 0		; Drive A
	int	0x13
	jc	.boot_no_copy
	; Copy boot code (0x3E to 0x1FD) from drive A's boot sector
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
; Disk I/O — read/write sector using LBA
; ============================================================================
; AX = LBA sector number, BX = buffer (DS:BX)
write_sector:
	push	ax
	push	bx
	push	cx
	push	dx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301	; Write 1 sector
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
	mov	ax, 0x0201	; Read 1 sector
	int	0x13
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; LBA in AX → CHS in CH/CL/DH, BX preserved
lba_to_chs:
	push	bx
	xor	dx, dx
	mov	bx, SPT * HEADS
	div	bx
	mov	ch, al		; Cylinder
	mov	ax, dx
	xor	dx, dx
	mov	bx, SPT
	div	bx
	mov	dh, al		; Head
	mov	cl, dl
	inc	cl		; Sector (1-based)
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
; Data
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

oem_name	db	'MEGADOS '
shell_fname	db	'SHELL.COM', 0

drive		db	0
opt_sys		db	0
opt_quick	db	0
vol_label	times 11 db 0
sys_handle	dw	0
sys_size	dd	0
sys_clusters	dw	0
cur_cluster	dw	0
cur_lba		dw	0

; Sector buffer — must be at least 1024 bytes for FAT write
sector_buf:
