; CHKDSK.COM — Check disk for FAT12 filesystem errors
; Usage: CHKDSK [drive:] [/F]
;   /F = fix errors (free lost clusters)
; Reads BPB from boot sector — works with any FAT12 floppy format.
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

	; Default to current drive
	mov	ah, 0x19
	int	0x21
	mov	[drive], al

	; Check for drive letter
	cmp	byte [si], 0x0D
	je	.parse_done
	cmp	byte [si], 0
	je	.parse_done
	cmp	byte [si], '/'
	je	.parse_switches

	; Drive letter
	mov	al, [si]
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

.parse_switches:
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
	cmp	al, 'f'
	jne	usage
	mov	byte [opt_fix], 1
	inc	si
	jmp	.parse_switches

.parse_done:
	; Print header
	call	crlf
	mov	al, [drive]
	add	al, 'A'
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	si, msg_header
	call	pstr

	; ============================================================
	; Step 1: Read boot sector and parse BPB
	; ============================================================
	mov	bx, boot_buf
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1		; Sector 1 = LBA 0
	mov	dh, 0
	mov	dl, [drive]
	int	0x13
	jc	read_err

	; Extract BPB fields
	mov	ax, [boot_buf+11]
	mov	[bpb_bps], ax		; Bytes per sector
	mov	al, [boot_buf+13]
	mov	[bpb_spc], al		; Sectors per cluster
	mov	ax, [boot_buf+14]
	mov	[bpb_reserved], ax	; Reserved sectors
	mov	al, [boot_buf+16]
	mov	[bpb_nfats], al		; Number of FATs
	mov	ax, [boot_buf+17]
	mov	[bpb_rootents], ax	; Root entries
	mov	ax, [boot_buf+19]
	mov	[bpb_totsec], ax	; Total sectors
	mov	al, [boot_buf+21]
	mov	[bpb_media], al		; Media byte
	mov	ax, [boot_buf+22]
	mov	[bpb_spf], ax		; Sectors per FAT
	mov	ax, [boot_buf+24]
	mov	[bpb_spt], ax		; Sectors per track
	mov	ax, [boot_buf+26]
	mov	[bpb_heads], ax		; Heads

	; Calculate derived values
	; fat_start = reserved sectors
	mov	ax, [bpb_reserved]
	mov	[fat_start], ax

	; root_dir_sec = reserved + (nfats * spf)
	xor	ah, ah
	mov	al, [bpb_nfats]
	mul	word [bpb_spf]
	add	ax, [bpb_reserved]
	mov	[root_dir_sec], ax

	; root_dir_secs = (root_entries * 32 + bps - 1) / bps
	mov	ax, [bpb_rootents]
	mov	cl, 5
	shl	ax, cl			; * 32
	add	ax, [bpb_bps]
	dec	ax
	xor	dx, dx
	div	word [bpb_bps]
	mov	[root_dir_secs], ax

	; data_start = root_dir_sec + root_dir_secs
	mov	ax, [root_dir_sec]
	add	ax, [root_dir_secs]
	mov	[data_start], ax

	; total_clusters = (total_secs - data_start) / spc
	mov	ax, [bpb_totsec]
	sub	ax, [data_start]
	xor	dx, dx
	xor	bh, bh
	mov	bl, [bpb_spc]
	div	bx			; AX = data clusters
	mov	[total_clusters], ax
	; max_cluster = total_clusters + 1 (clusters 2..total_clusters+1)
	inc	ax
	mov	[max_cluster], ax

	; bytes_per_cluster
	xor	ah, ah
	mov	al, [bpb_spc]
	mul	word [bpb_bps]
	mov	[bytes_per_clust], ax

	; ============================================================
	; Step 2: Read FAT
	; ============================================================
	mov	bx, fat_buf
	mov	ax, [fat_start]
	mov	cx, [bpb_spf]
.read_fat:
	push	cx
	push	ax
	push	bx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
	pop	bx
	pop	ax
	pop	cx
	jc	read_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.read_fat

	; ============================================================
	; Step 3: Clear cluster usage map
	; ============================================================
	mov	di, cluster_map
	xor	al, al
	mov	cx, [max_cluster]
	inc	cx
	rep	stosb
	mov	byte [cluster_map], 2
	mov	byte [cluster_map+1], 2

	; Zero counters
	mov	word [file_count], 0
	mov	word [dir_count], 0
	mov	word [bytes_lo], 0
	mov	word [bytes_hi], 0
	mov	word [lost_chains], 0
	mov	word [lost_clusters], 0
	mov	word [crosslinked], 0
	mov	word [free_clusters], 0
	mov	byte [fat_dirty], 0

	; ============================================================
	; Step 4: Read root directory and walk file chains
	; ============================================================
	mov	bx, dir_buf
	mov	ax, [root_dir_sec]
	mov	cx, [root_dir_secs]
.read_rootdir:
	push	cx
	push	ax
	push	bx
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
	pop	bx
	pop	ax
	pop	cx
	jc	read_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.read_rootdir

	mov	si, dir_buf
	mov	cx, [bpb_rootents]
	call	walk_directory

	; ============================================================
	; Step 5: Find lost clusters
	; ============================================================
	mov	ax, 2
.check_lost:
	cmp	ax, [max_cluster]
	ja	.lost_done
	push	ax
	call	fat12_read
	cmp	ax, 0
	je	.not_lost

	pop	ax
	push	ax
	mov	bx, ax
	cmp	byte [cluster_map + bx], 0
	jne	.not_lost

	inc	word [lost_clusters]
	pop	ax
	push	ax
	call	is_chain_start
	jnc	.not_chain_start
	inc	word [lost_chains]

	cmp	byte [opt_fix], 1
	jne	.not_chain_start
	pop	ax
	push	ax
	call	free_chain

.not_chain_start:
.not_lost:
	pop	ax
	inc	ax
	jmp	.check_lost
.lost_done:

	; ============================================================
	; Step 6: Count free clusters
	; ============================================================
	mov	ax, 2
.count_free:
	cmp	ax, [max_cluster]
	ja	.count_done
	push	ax
	call	fat12_read
	cmp	ax, 0
	pop	ax
	jne	.not_free
	inc	word [free_clusters]
.not_free:
	inc	ax
	jmp	.count_free
.count_done:

	; ============================================================
	; Step 7: Write FAT back if changed
	; ============================================================
	cmp	byte [fat_dirty], 0
	je	.no_fat_write
	; Write FAT1
	mov	bx, fat_buf
	mov	ax, [fat_start]
	mov	cx, [bpb_spf]
	call	write_fat_copy
	jc	write_err
	; Write FAT2
	mov	bx, fat_buf
	mov	ax, [fat_start]
	add	ax, [bpb_spf]
	mov	cx, [bpb_spf]
	call	write_fat_copy
	jc	write_err
.no_fat_write:

	; ============================================================
	; Step 8: Print report
	; ============================================================
	call	crlf

	; Total disk space
	mov	ax, [bpb_totsec]
	mov	bx, [bpb_bps]
	mul	bx
	call	pdec32
	mov	si, msg_total
	call	pstr

	; Bytes in files
	mov	ax, [bytes_lo]
	mov	dx, [bytes_hi]
	call	pdec32
	mov	si, msg_in_files
	call	pstr
	mov	ax, [file_count]
	call	pdec
	mov	si, msg_files_suf
	call	pstr

	; Directories
	cmp	word [dir_count], 0
	je	.no_dir_report
	mov	ax, [dir_count]
	mov	bx, [bytes_per_clust]
	mul	bx
	call	pdec32
	mov	si, msg_in_dirs
	call	pstr
.no_dir_report:

	; Lost clusters
	cmp	word [lost_clusters], 0
	je	.no_lost_report
	call	crlf
	mov	ax, [lost_clusters]
	call	pdec
	mov	si, msg_lost_clust
	call	pstr
	mov	ax, [lost_chains]
	call	pdec
	mov	si, msg_lost_chains
	call	pstr
	cmp	byte [opt_fix], 1
	jne	.lost_not_fixed
	mov	si, msg_freed
	call	pstr
	jmp	.no_lost_report
.lost_not_fixed:
	mov	si, msg_use_f
	call	pstr
.no_lost_report:

	; Cross-linked
	cmp	word [crosslinked], 0
	je	.no_cross_report
	call	crlf
	mov	ax, [crosslinked]
	call	pdec
	mov	si, msg_crosslink
	call	pstr
.no_cross_report:

	; Free space
	call	crlf
	mov	ax, [free_clusters]
	mov	bx, [bytes_per_clust]
	mul	bx
	call	pdec32
	mov	si, msg_free
	call	pstr

	; Cluster info
	mov	ax, [total_clusters]
	call	pdec
	mov	si, msg_total_alloc
	call	pstr
	mov	ax, [bytes_per_clust]
	call	pdec
	mov	si, msg_bytes_each
	call	pstr

	; Errors summary
	call	crlf
	mov	ax, [lost_clusters]
	add	ax, [crosslinked]
	cmp	ax, 0
	je	.no_errors
	cmp	byte [opt_fix], 1
	jne	.has_errors
	mov	si, msg_errors_fixed
	call	pstr
	jmp	exit
.has_errors:
	mov	si, msg_errors_found
	call	pstr
	jmp	exit
.no_errors:
	mov	si, msg_no_errors
	call	pstr

exit:
	mov	ax, 0x4C00
	int	0x21

usage:
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

read_err:
	mov	si, msg_read_err
	call	pstr
	mov	ax, 0x4C02
	int	0x21

write_err:
	mov	si, msg_write_err
	call	pstr
	mov	ax, 0x4C02
	int	0x21

; ============================================================================
; write_fat_copy — Write FAT sectors starting at LBA AX, CX sectors, from BX
; ============================================================================
write_fat_copy:
	push	ax
	push	bx
	push	cx
.wfc_loop:
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
	jc	.wfc_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.wfc_loop
	pop	cx
	pop	bx
	pop	ax
	clc
	ret
.wfc_err:
	pop	cx
	pop	bx
	pop	ax
	stc
	ret

; ============================================================================
; walk_directory — Scan dir entries, walk each file's cluster chain
; SI = directory buffer, CX = entry count
; ============================================================================
walk_directory:
.wd_loop:
	cmp	byte [si], 0
	je	.wd_done
	cmp	byte [si], 0xE5
	je	.wd_next

	mov	al, [si+11]
	test	al, 0x08
	jnz	.wd_next		; Volume label

	test	al, 0x10
	jnz	.wd_dir

	; Regular file
	inc	word [file_count]
	mov	ax, [si+28]
	add	[bytes_lo], ax
	mov	ax, [si+30]
	adc	[bytes_hi], ax
	mov	ax, [si+26]
	cmp	ax, 0
	je	.wd_next
	push	si
	push	cx
	call	walk_chain
	pop	cx
	pop	si
	jmp	.wd_next

.wd_dir:
	cmp	byte [si], '.'
	je	.wd_next
	inc	word [dir_count]
	mov	ax, [si+26]
	cmp	ax, 0
	je	.wd_next
	push	si
	push	cx
	call	walk_chain
	pop	cx
	pop	si

.wd_next:
	add	si, 32
	dec	cx
	jnz	.wd_loop
.wd_done:
	ret

; ============================================================================
; walk_chain — Walk FAT12 chain, mark clusters in cluster_map
; ============================================================================
walk_chain:
.wc_loop:
	cmp	ax, 2
	jb	.wc_done
	cmp	ax, [max_cluster]
	ja	.wc_done

	mov	bx, ax
	cmp	byte [cluster_map + bx], 0
	jne	.wc_crosslink
	mov	byte [cluster_map + bx], 1

	call	fat12_read
	cmp	ax, 0xFF8
	jb	.wc_loop
.wc_done:
	ret
.wc_crosslink:
	inc	word [crosslinked]
	ret

; ============================================================================
; fat12_read — Read FAT12 entry for cluster AX → AX
; ============================================================================
fat12_read:
	push	bx
	push	cx
	mov	bx, ax
	mov	cx, ax
	shr	bx, 1
	add	bx, cx		; BX = cluster * 1.5
	mov	ax, [fat_buf + bx]
	test	cx, 1
	jnz	.fat_odd
	and	ax, 0x0FFF
	jmp	.fat_done
.fat_odd:
	mov	cl, 4
	shr	ax, cl
.fat_done:
	pop	cx
	pop	bx
	ret

; ============================================================================
; fat12_write — Write 12-bit value BX into FAT entry AX
; ============================================================================
fat12_write:
	push	cx
	push	dx
	push	si
	mov	si, ax
	mov	cx, ax
	shr	si, 1
	add	si, cx
	mov	dx, [fat_buf + si]
	test	cx, 1
	jnz	.fw_odd
	and	dx, 0xF000
	or	dx, bx
	jmp	.fw_store
.fw_odd:
	and	dx, 0x000F
	push	cx
	mov	cl, 4
	shl	bx, cl
	pop	cx
	or	dx, bx
.fw_store:
	mov	[fat_buf + si], dx
	pop	si
	pop	dx
	pop	cx
	ret

; ============================================================================
; is_chain_start — CF=1 if no other FAT entry points to cluster AX
; ============================================================================
is_chain_start:
	push	bx
	push	cx
	push	ax
	mov	cx, ax
	mov	ax, 2
.ics_loop:
	cmp	ax, [max_cluster]
	ja	.ics_is_start
	cmp	ax, cx
	je	.ics_skip
	push	cx
	push	ax
	call	fat12_read
	cmp	ax, cx
	pop	ax
	pop	cx
	je	.ics_not_start
.ics_skip:
	inc	ax
	jmp	.ics_loop
.ics_is_start:
	pop	ax
	pop	cx
	pop	bx
	stc
	ret
.ics_not_start:
	pop	ax
	pop	cx
	pop	bx
	clc
	ret

; ============================================================================
; free_chain — Free all clusters in chain starting at AX
; ============================================================================
free_chain:
	push	ax
	push	bx
.fc_loop:
	cmp	ax, 2
	jb	.fc_done
	cmp	ax, [max_cluster]
	ja	.fc_done
	cmp	ax, 0xFF8
	jae	.fc_done

	push	ax
	call	fat12_read
	mov	bx, ax
	pop	ax

	push	bx
	xor	bx, bx
	call	fat12_write
	pop	bx
	mov	byte [fat_dirty], 1

	mov	ax, bx
	jmp	.fc_loop
.fc_done:
	pop	bx
	pop	ax
	ret

; ============================================================================
; LBA to CHS — uses BPB variables
; AX = LBA → CH=cyl, CL=sector, DH=head
; ============================================================================
lba_to_chs:
	push	bx
	push	ax
	; Compute SPT * HEADS
	push	ax
	mov	ax, [bpb_spt]
	mul	word [bpb_heads]	; AX = SPT * HEADS
	mov	bx, ax
	pop	ax
	; AX=LBA / BX=(SPT*HEADS) → AX=cylinder, DX=remainder
	xor	dx, dx
	div	bx
	mov	ch, al		; Cylinder
	; DX=remainder / SPT → AX=head, DX=sector
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

pdec32:
	push	cx
	push	bx
	push	si
	push	di
	xor	cx, cx
	mov	si, dx
.d32_loop:
	push	ax
	mov	ax, si
	xor	dx, dx
	mov	bx, 10
	div	bx
	mov	si, ax
	pop	ax
	push	dx
	pop	bx
	push	bx
	mov	dx, bx
	mov	bx, 10
	div	bx
	pop	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.d32_loop
	or	si, si
	jnz	.d32_loop
.d32_print:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.d32_print
	pop	di
	pop	si
	pop	bx
	pop	cx
	ret

; ============================================================================
; Messages
; ============================================================================
msg_usage	db	'Usage: CHKDSK [drive:] [/F]', 0x0D, 0x0A, 0
msg_header	db	': Checking disk...', 0x0D, 0x0A, 0
msg_read_err	db	'Disk read error', 0x0D, 0x0A, 0
msg_write_err	db	'Disk write error', 0x0D, 0x0A, 0
msg_total	db	' bytes total disk space', 0x0D, 0x0A, 0
msg_in_files	db	' bytes in ', 0
msg_files_suf	db	' user files', 0x0D, 0x0A, 0
msg_in_dirs	db	' bytes in directories', 0x0D, 0x0A, 0
msg_free	db	' bytes available on disk', 0x0D, 0x0A, 0
msg_total_alloc	db	' total allocation units on disk', 0x0D, 0x0A, 0
msg_bytes_each	db	' bytes in each allocation unit', 0x0D, 0x0A, 0
msg_lost_clust	db	' lost clusters found in ', 0
msg_lost_chains	db	' chains', 0x0D, 0x0A, 0
msg_freed	db	'  Lost clusters freed.', 0x0D, 0x0A, 0
msg_use_f	db	'  Use /F to free lost clusters.', 0x0D, 0x0A, 0
msg_crosslink	db	' cross-linked clusters found', 0x0D, 0x0A, 0
msg_no_errors	db	'No errors found.', 0x0D, 0x0A, 0
msg_errors_found db	'Errors found.', 0x0D, 0x0A, 0
msg_errors_fixed db	'Errors corrected.', 0x0D, 0x0A, 0

; ============================================================================
; Data — BPB variables
; ============================================================================
drive		db	0
opt_fix		db	0
fat_dirty	db	0

bpb_bps		dw	0	; Bytes per sector
bpb_spc		db	0	; Sectors per cluster
bpb_reserved	dw	0	; Reserved sectors
bpb_nfats	db	0	; Number of FATs
bpb_rootents	dw	0	; Root directory entries
bpb_totsec	dw	0	; Total sectors
bpb_media	db	0	; Media descriptor
bpb_spf		dw	0	; Sectors per FAT
bpb_spt		dw	0	; Sectors per track
bpb_heads	dw	0	; Number of heads

; Derived values
fat_start	dw	0
root_dir_sec	dw	0
root_dir_secs	dw	0
data_start	dw	0
total_clusters	dw	0
max_cluster	dw	0	; Highest valid cluster number
bytes_per_clust	dw	0

; Counters
file_count	dw	0
dir_count	dw	0
bytes_lo	dw	0
bytes_hi	dw	0
lost_clusters	dw	0
lost_chains	dw	0
crosslinked	dw	0
free_clusters	dw	0

; Buffers at end of program
boot_buf:	times 512 db 0		; Boot sector
fat_buf:	times 4608 db 0		; FAT (up to 9 sectors for 1.44MB)
cluster_map:	times 2850 db 0		; 1 byte per cluster (max ~2847 for 1.44MB)
dir_buf:					; Root directory (variable size)
