; SYS.COM — Transfer system files to make a disk bootable
; Usage: SYS drive:
; Copies boot code and COMMAND.COM to the target disk without formatting.
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
	call	skip_sp
	cmp	byte [si], 0x0D
	je	.parse_done
	cmp	byte [si], 0
	jne	usage

.parse_done:
	; Step 1: Read target drive's boot sector (to preserve BPB)
	mov	si, msg_reading
	call	pstr
	mov	bx, sector_buf
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, [drive]
	int	0x13
	jc	.target_err

	; Step 2: Read drive A's boot sector (source of boot code)
	mov	bx, sector_buf + 512
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, 0			; Drive A
	int	0x13
	jc	.source_err

	; Step 3: Copy boot code from A to target (preserve target's BPB)
	; BPB is at bytes 0x0B-0x3D, boot code is at 0x3E-0x1FD
	mov	si, msg_boot
	call	pstr
	; Copy jump instruction (3 bytes)
	mov	si, sector_buf + 512
	mov	di, sector_buf
	movsb				; Byte 0: JMP
	movsb				; Byte 1: offset
	movsb				; Byte 2: NOP
	; Skip BPB (bytes 3-61 = 0x03-0x3D) — keep target's BPB
	; Copy boot code (bytes 62-509 = 0x3E-0x1FD)
	mov	si, sector_buf + 512 + 0x3E
	mov	di, sector_buf + 0x3E
	mov	cx, 0x1FE - 0x3E
	rep	movsb
	; Keep boot signature (0x55AA already there if formatted)
	mov	byte [sector_buf + 510], 0x55
	mov	byte [sector_buf + 511], 0xAA

	; Write modified boot sector back to target
	mov	bx, sector_buf
	mov	ah, 0x03
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, [drive]
	int	0x13
	jc	.write_err

	; Step 4: Copy COMMAND.COM to target disk
	mov	si, msg_shell
	call	pstr

	; Open COMMAND.COM on current drive
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, shell_fname
	int	0x21
	jc	.no_shell
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

	; Read BPB from target to get geometry
	; We already have it in sector_buf (target boot sector)
	mov	si, sector_buf
	mov	al, [si+13]		; SPC
	xor	ah, ah
	mov	[bpb_spc], ax
	mov	ax, [si+22]		; SPF
	mov	[bpb_spf], ax
	mov	ax, [si+24]		; SPT
	mov	[bpb_spt], ax
	mov	ax, [si+26]		; Heads
	mov	[bpb_heads], ax
	; root_dir_sec = reserved + nfats * spf
	mov	al, [si+16]		; nfats
	xor	ah, ah
	mov	bx, [si+22]		; spf
	add	bx, bx			; * 2 (always 2 FATs)
	add	bx, [si+14]		; + reserved
	mov	[root_dir_sec], bx
	; root_dir_secs = root_entries / 16
	mov	ax, [si+17]		; root entries
	mov	[bpb_rootents], ax
	mov	cl, 4
	shr	ax, cl
	mov	[root_dir_secs], ax
	; data_start = root_dir_sec + root_dir_secs
	add	ax, bx
	mov	[data_start], ax
	; bytes per cluster
	mov	ax, [bpb_spc]
	mov	cl, 9
	shl	ax, cl
	mov	[bytes_per_clust], ax

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
	jc	.copy_err
	cmp	ax, 0
	je	.sys_read_done
	mov	[.bytes_read], ax

	; Write sectors of this cluster to target
	push	ax
	xor	ch, ch
	mov	cl, [bpb_spc]
	mov	bx, sector_buf
	mov	ax, [cur_lba]
.sys_write_secs:
	push	cx
	push	ax
	push	bx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
	pop	bx
	pop	ax
	pop	cx
	jc	.write_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sys_write_secs
	; Advance LBA
	mov	ax, [cur_lba]
	xor	ch, ch
	mov	cl, [bpb_spc]
	add	ax, cx
	mov	[cur_lba], ax
	pop	ax

	; Track cluster
	inc	word [cur_cluster]

	; More data?
	mov	ax, [.bytes_read]
	cmp	ax, [bytes_per_clust]
	je	.sys_read_loop

.sys_read_done:
	; Close file
	mov	ah, 0x3E
	mov	bx, [sys_handle]
	int	0x21

	; Build FAT with cluster chain
	mov	si, msg_fat
	call	pstr
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	mov	ax, [bpb_spf]
	mov	bx, 256
	mul	bx			; AX = words to clear
	mov	cx, ax
	xor	ax, ax
	rep	stosw

	; Read target's existing FAT first sector to get media byte
	mov	bx, sector_buf + 512	; temp
	mov	ax, 1			; FAT1 starts at LBA 1
	push	bx
	call	lba_to_chs
	pop	bx
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
	jc	.write_err
	; Get media byte from existing FAT
	mov	al, [sector_buf + 512]
	mov	[sector_buf], al	; Media byte
	mov	byte [sector_buf+1], 0xFF
	mov	byte [sector_buf+2], 0xFF

	; Write cluster chain: 2→3→4→...→EOF
	mov	ax, 2
	mov	cx, [cur_cluster]
	sub	cx, 2			; Clusters used
	dec	cx			; Last one gets EOF
.sys_fat_chain:
	jcxz	.sys_fat_eof
	push	cx
	mov	bx, ax
	inc	bx			; Next cluster
	call	fat12_write
	pop	cx
	inc	ax
	dec	cx
	jmp	.sys_fat_chain
.sys_fat_eof:
	mov	bx, 0xFFF
	call	fat12_write

	; Write FAT1
	mov	bx, sector_buf
	mov	ax, 1			; FAT1 at LBA 1
	mov	cx, [bpb_spf]
.wf1:
	push	cx
	push	ax
	push	bx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
	pop	bx
	pop	ax
	pop	cx
	jc	.write_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.wf1
	; Write FAT2
	mov	bx, sector_buf
	mov	ax, [bpb_spf]
	inc	ax			; FAT2 = reserved + spf
	mov	cx, [bpb_spf]
.wf2:
	push	cx
	push	ax
	push	bx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
	pop	bx
	pop	ax
	pop	cx
	jc	.write_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.wf2

	; Write root directory entry for COMMAND.COM
	; Read existing first root dir sector
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	push	bx
	push	ax
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
	pop	ax
	pop	bx
	jc	.write_err

	; Find first empty or deleted slot (preserve existing entries)
	mov	di, sector_buf
	mov	cx, 16			; 16 entries per sector
.find_slot:
	cmp	byte [di], 0		; Empty
	je	.got_slot
	cmp	byte [di], 0xE5		; Deleted
	je	.got_slot
	; Check if COMMAND.COM already exists — overwrite it
	cmp	byte [di], 'C'
	jne	.next_slot
	push	si
	push	di
	push	cx
	mov	si, shell_83name
	mov	cx, 11
	repe	cmpsb
	pop	cx
	pop	di
	pop	si
	je	.got_slot		; Found existing COMMAND.COM entry
.next_slot:
	add	di, 32
	dec	cx
	jnz	.find_slot
	; No empty slot in first sector — use first entry
	mov	di, sector_buf
.got_slot:
	; Write COMMAND.COM directory entry
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
	mov	byte [di+11], 0x20	; Archive
	mov	word [di+26], 2		; Start cluster
	mov	ax, [sys_size]
	mov	[di+28], ax
	mov	ax, [sys_size+2]
	mov	[di+30], ax

	; Write root dir sector back
	push	cs
	pop	es
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	push	bx
	push	ax
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
	pop	ax
	pop	bx
	jc	.write_err

	; Done!
	call	crlf
	mov	si, msg_done
	call	pstr
	jmp	exit

.target_err:
	mov	si, msg_target_err
	call	pstr
	jmp	exit

.source_err:
	mov	si, msg_source_err
	call	pstr
	jmp	exit

.no_shell:
	mov	si, msg_no_shell
	call	pstr
	jmp	exit

.copy_err:
	mov	si, msg_copy_err
	call	pstr
	jmp	exit

.write_err:
	mov	si, msg_write_err
	call	pstr
	jmp	exit

.bytes_read:	dw	0

exit:
	mov	ax, 0x4C00
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

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
; LBA to CHS — uses BPB variables
; ============================================================================
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
	mov	ch, al
	mov	ax, dx
	xor	dx, dx
	div	word [bpb_spt]
	mov	dh, al
	mov	cl, dl
	inc	cl
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

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: SYS drive:', 0x0D, 0x0A, 0
msg_reading	db	'Reading target disk...', 0x0D, 0x0A, 0
msg_boot	db	'  Transferring boot code', 0x0D, 0x0A, 0
msg_shell	db	'  Copying COMMAND.COM', 0x0D, 0x0A, 0
msg_fat		db	'  Updating FAT', 0x0D, 0x0A, 0
msg_done	db	'System transferred.', 0x0D, 0x0A, 0
msg_target_err	db	'Cannot read target disk', 0x0D, 0x0A, 0
msg_source_err	db	'Cannot read boot sector from A:', 0x0D, 0x0A, 0
msg_no_shell	db	'COMMAND.COM not found', 0x0D, 0x0A, 0
msg_copy_err	db	'Error reading COMMAND.COM', 0x0D, 0x0A, 0
msg_write_err	db	'Disk write error', 0x0D, 0x0A, 0

shell_fname	db	'COMMAND.COM', 0
shell_83name	db	'COMMAND COM'

; ============================================================================
; Data
; ============================================================================
drive		db	0
sys_handle	dw	0
sys_size	dd	0
cur_cluster	dw	0
cur_lba		dw	0

; BPB variables (read from target disk)
bpb_spc		dw	0
bpb_spf		dw	0
bpb_spt		dw	0
bpb_heads	dw	0
bpb_rootents	dw	0
root_dir_sec	dw	0
root_dir_secs	dw	0
data_start	dw	0
bytes_per_clust	dw	0

; Sector buffer — needs room for cluster data + temp boot sector
sector_buf:
