; TREE.COM — Display directory structure
; Usage: TREE [drive:]
	cpu	8086
	org	0x0100

MAX_DEPTH	equ	8

start:
	push	cs
	pop	ds
	push	cs
	pop	es
	cld

	; Shrink memory block
	mov	ah, 0x4A
	mov	bx, (end_of_prog - start + 0x100 + 15) / 16
	push	cs
	pop	es
	int	0x21

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
	cmp	byte [si+1], ':'
	jne	.parse_done
	mov	al, [si]
	or	al, 0x20
	cmp	al, 'a'
	jb	.parse_done
	cmp	al, 'z'
	ja	.parse_done
	sub	al, 'a'
	mov	[drive], al

.parse_done:
	; Read boot sector for geometry
	mov	bx, sector_buf
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, [drive]
	int	0x13
	jc	disk_err

	; Parse BPB
	mov	si, sector_buf
	mov	ax, [si+24]
	mov	[bpb_spt], ax
	mov	ax, [si+26]
	mov	[bpb_heads], ax
	mov	al, [si+13]
	xor	ah, ah
	mov	[bpb_spc], ax
	; root_dir_sec = reserved + nfats * spf
	mov	al, [si+16]
	xor	ah, ah
	mov	bx, [si+22]
	add	bx, bx
	add	bx, [si+14]
	mov	[root_dir_sec], bx
	; root_dir_secs
	mov	ax, [si+17]
	mov	[bpb_rootents], ax
	mov	cl, 4
	shr	ax, cl
	mov	[root_dir_secs], ax
	; data_start
	add	ax, bx
	mov	[data_start], ax
	; entries per cluster
	mov	ax, [bpb_spc]
	mov	cl, 4
	shl	ax, cl
	mov	[entries_per_clust], ax

	; Print header
	mov	al, [drive]
	add	al, 'A'
	call	putch
	mov	al, ':'
	call	putch
	mov	al, '\'
	call	putch
	call	crlf

	; Start from root (cluster 0)
	mov	word [depth], 0
	mov	ax, 0
	call	show_dir

	call	crlf
	jmp	exit

disk_err:
	mov	si, msg_disk_err
	call	pstr
	mov	ax, 0x4C02
	int	0x21

exit:
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; show_dir — Display directory tree for cluster AX (0=root)
; Uses entry-index approach: processes one entry at a time,
; re-reading the directory before each entry to handle recursion.
; ============================================================================
show_dir:
	push	ax
	push	bx
	push	cx

	cmp	word [depth], MAX_DEPTH
	jae	.sd_ret

	mov	[.sd_cluster], ax

	; First: count visible entries (to know which is last)
	call	.sd_read_dir
	jc	.sd_ret
	mov	word [.sd_total], 0
	mov	si, dir_buf
	mov	cx, [.sd_max_ent]
.sd_count:
	cmp	byte [si], 0
	je	.sd_counted
	cmp	byte [si], 0xE5
	je	.sd_count_next
	cmp	byte [si], '.'
	je	.sd_count_next
	mov	al, [si+11]
	test	al, 0x08
	jnz	.sd_count_next
	test	al, 0x06
	jnz	.sd_count_next
	inc	word [.sd_total]
.sd_count_next:
	add	si, 32
	dec	cx
	jnz	.sd_count
.sd_counted:

	; Process entries by index
	mov	word [.sd_vis_idx], 0	; Visible entry index
	mov	word [.sd_raw_idx], 0	; Raw entry index

.sd_next_entry:
	; Re-read directory (may have been clobbered by recursion)
	call	.sd_read_dir
	jc	.sd_ret

	; Skip to raw_idx
	mov	si, dir_buf
	mov	cx, [.sd_raw_idx]
	jcxz	.sd_at_entry
	mov	ax, cx
	mov	cl, 5
	shl	ax, cl			; * 32
	add	si, ax
.sd_at_entry:
	; Check if past end
	mov	ax, [.sd_raw_idx]
	cmp	ax, [.sd_max_ent]
	jae	.sd_ret
	cmp	byte [si], 0
	je	.sd_ret

	inc	word [.sd_raw_idx]

	; Skip deleted, dot, volume labels, hidden/system
	cmp	byte [si], 0xE5
	je	.sd_next_entry
	cmp	byte [si], '.'
	je	.sd_next_entry
	mov	al, [si+11]
	test	al, 0x08
	jnz	.sd_next_entry
	test	al, 0x06
	jnz	.sd_next_entry

	inc	word [.sd_vis_idx]

	; Print tree prefix
	call	print_prefix

	; Is this the last visible entry?
	mov	ax, [.sd_vis_idx]
	cmp	ax, [.sd_total]
	jne	.sd_not_last
	push	si
	mov	si, msg_corner
	call	pstr
	pop	si
	jmp	.sd_print_name
.sd_not_last:
	push	si
	mov	si, msg_tee
	call	pstr
	pop	si

.sd_print_name:
	; Print 8.3 filename
	push	si
	push	cx
	mov	cx, 8
.sd_pn_name:
	lodsb
	cmp	al, ' '
	je	.sd_pn_skip_name
	call	putch
	dec	cx
	jnz	.sd_pn_name
	jmp	.sd_pn_ext_check
.sd_pn_skip_name:
	; Skip remaining name spaces
	dec	cx
	add	si, cx
.sd_pn_ext_check:
	mov	al, [si]
	cmp	al, ' '
	je	.sd_pn_done
	push	ax
	mov	al, '.'
	call	putch
	pop	ax
	mov	cx, 3
.sd_pn_ext:
	lodsb
	cmp	al, ' '
	je	.sd_pn_done
	call	putch
	dec	cx
	jnz	.sd_pn_ext
.sd_pn_done:
	pop	cx
	pop	si
	call	crlf

	; If directory, recurse
	test	byte [si+11], 0x10
	jz	.sd_next_entry

	mov	ax, [si+26]		; Subdirectory cluster
	cmp	ax, 0
	je	.sd_next_entry

	; Set last_flags for current depth
	push	bx
	mov	bx, [depth]
	mov	cx, [.sd_vis_idx]
	cmp	cx, [.sd_total]
	jne	.sd_flag_not_last
	mov	byte [last_flags + bx], 1
	jmp	.sd_flag_set
.sd_flag_not_last:
	mov	byte [last_flags + bx], 0
.sd_flag_set:
	pop	bx

	; Save state and recurse
	push	word [.sd_cluster]
	push	word [.sd_total]
	push	word [.sd_vis_idx]
	push	word [.sd_raw_idx]
	push	word [.sd_max_ent]

	inc	word [depth]
	call	show_dir
	dec	word [depth]

	pop	word [.sd_max_ent]
	pop	word [.sd_raw_idx]
	pop	word [.sd_vis_idx]
	pop	word [.sd_total]
	pop	word [.sd_cluster]

	jmp	.sd_next_entry

.sd_ret:
	pop	cx
	pop	bx
	pop	ax
	ret

; --- Read directory for current .sd_cluster into dir_buf ---
; Sets .sd_max_ent. Returns CF on error.
.sd_read_dir:
	mov	ax, [.sd_cluster]
	cmp	ax, 0
	je	.sdr_root
	; Subdirectory
	sub	ax, 2
	mul	word [bpb_spc]
	add	ax, [data_start]
	mov	cx, [bpb_spc]
	mov	bx, dir_buf
.sdr_sub_loop:
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
	jc	.sdr_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sdr_sub_loop
	mov	ax, [entries_per_clust]
	mov	[.sd_max_ent], ax
	clc
	ret
.sdr_root:
	mov	bx, dir_buf
	mov	ax, [root_dir_sec]
	mov	cx, [root_dir_secs]
.sdr_root_loop:
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
	jc	.sdr_err
	add	bx, 512
	inc	ax
	dec	cx
	jnz	.sdr_root_loop
	mov	ax, [bpb_rootents]
	mov	[.sd_max_ent], ax
	clc
	ret
.sdr_err:
	stc
	ret

.sd_cluster:	dw	0
.sd_total:	dw	0
.sd_vis_idx:	dw	0
.sd_raw_idx:	dw	0
.sd_max_ent:	dw	0

; ============================================================================
; print_prefix — Print tree indentation for current depth
; ============================================================================
print_prefix:
	push	cx
	push	bx
	mov	cx, [depth]
	jcxz	.pp_done
	xor	bx, bx
.pp_loop:
	cmp	byte [last_flags + bx], 1
	je	.pp_space
	push	si
	mov	si, msg_vert
	call	pstr
	pop	si
	jmp	.pp_next
.pp_space:
	push	si
	mov	si, msg_space
	call	pstr
	pop	si
.pp_next:
	inc	bx
	dec	cx
	jnz	.pp_loop
.pp_done:
	pop	bx
	pop	cx
	ret

; ============================================================================
; LBA to CHS
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

putch:
	push	ax
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
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
msg_tee		db	'+---', 0
msg_corner	db	'\---', 0
msg_vert	db	'|   ', 0
msg_space	db	'    ', 0
msg_disk_err	db	'Disk read error', 0x0D, 0x0A, 0

; ============================================================================
; Data
; ============================================================================
drive		db	0
depth		dw	0
last_flags	times MAX_DEPTH db 0

bpb_spt		dw	0
bpb_heads	dw	0
bpb_spc		dw	0
bpb_rootents	dw	0
root_dir_sec	dw	0
root_dir_secs	dw	0
data_start	dw	0
entries_per_clust dw	0

; Buffers
sector_buf	times 512 db 0
dir_buf:

end_of_prog equ dir_buf + 14 * 512	; Reserve space for largest root dir
