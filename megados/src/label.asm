; LABEL.COM — Set, change, or remove a disk volume label
; Usage: LABEL [drive:] [label]
;   No arguments: prompts for label on current drive
;   LABEL B: TEST  — sets label on drive B
;   LABEL B:       — prompts for label on drive B
;   Empty input    — removes existing label
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
	je	.no_args
	cmp	byte [si], 0
	je	.no_args

	; Check if first arg is a drive letter
	cmp	byte [si+1], ':'
	jne	.parse_label		; No colon — treat as label text

	; Drive letter
	mov	al, [si]
	or	al, 0x20
	cmp	al, 'a'
	jb	.parse_label
	cmp	al, 'z'
	ja	.parse_label
	sub	al, 'a'
	mov	[drive], al
	add	si, 2
	call	skip_sp

.parse_label:
	; Check if label text follows
	cmp	byte [si], 0x0D
	je	.no_args
	cmp	byte [si], 0
	je	.no_args

	; Copy label (up to 11 chars), uppercase, pad with spaces
	mov	di, new_label
	mov	cx, 11
.copy_label:
	mov	al, [si]
	cmp	al, 0x0D
	je	.pad_label
	cmp	al, 0
	je	.pad_label
	cmp	al, 'a'
	jb	.store_char
	cmp	al, 'z'
	ja	.store_char
	sub	al, 0x20
.store_char:
	stosb
	inc	si
	dec	cx
	jnz	.copy_label
.pad_label:
	mov	al, ' '
	rep	stosb
	mov	byte [have_label], 1
	jmp	.do_label

.no_args:
	; Show current label
	call	show_current_label

	; Prompt for new label
	mov	si, msg_prompt
	call	pstr
	; Read up to 11 chars
	mov	byte [input_buf], 11
	mov	byte [input_buf+1], 0
	mov	ah, 0x0A
	mov	dx, input_buf
	int	0x21
	call	crlf

	; Check if anything entered
	cmp	byte [input_buf+1], 0
	jne	.got_input

	; Empty input — ask to delete
	call	find_label
	jc	.no_existing		; No label to delete
	mov	si, msg_delete
	call	pstr
	mov	ah, 0x08
	int	0x21
	or	al, 0x20
	cmp	al, 'y'
	jne	.done
	call	crlf
	; Delete the label entry
	mov	byte [di], 0xE5		; Mark as deleted
	call	write_rootdir
	jc	.disk_err
	mov	si, msg_removed
	call	pstr
	jmp	.done

.no_existing:
	jmp	.done

.got_input:
	; Copy input to new_label, uppercase, pad
	mov	si, input_buf + 2
	mov	di, new_label
	xor	ch, ch
	mov	cl, [input_buf+1]
	push	cx
.copy_input:
	lodsb
	cmp	al, 'a'
	jb	.store_input
	cmp	al, 'z'
	ja	.store_input
	sub	al, 0x20
.store_input:
	stosb
	dec	cx
	jnz	.copy_input
	pop	cx
	; Pad remaining with spaces
	mov	cx, 11
	sub	cl, [input_buf+1]
	jbe	.input_padded
	mov	al, ' '
	rep	stosb
.input_padded:
	mov	byte [have_label], 1

.do_label:
	; Read root directory
	call	read_rootdir
	jc	.disk_err

	; Find existing label entry
	call	find_label
	jc	.create_new

	; Update existing label
	mov	si, new_label
	mov	cx, 11
	rep	movsb
	sub	di, 11		; DI back to entry start (movsb advanced it)
	call	write_rootdir
	jc	.disk_err
	mov	si, msg_set
	call	pstr
	jmp	.done

.create_new:
	; Find empty slot in root directory
	mov	di, sector_buf
	mov	cx, 16		; Entries per sector
.find_empty:
	cmp	byte [di], 0
	je	.found_empty
	cmp	byte [di], 0xE5
	je	.found_empty
	add	di, 32
	dec	cx
	jnz	.find_empty
	; No room in first sector
	mov	si, msg_no_room
	call	pstr
	jmp	.done

.found_empty:
	; Write label entry
	push	di
	mov	si, new_label
	mov	cx, 11
	rep	movsb
	pop	di
	mov	byte [di+11], 0x08	; Volume label attribute
	; Zero the rest of the entry (timestamps etc)
	push	di
	add	di, 12
	xor	al, al
	mov	cx, 20
	rep	stosb
	pop	di
	call	write_rootdir
	jc	.disk_err
	mov	si, msg_set
	call	pstr
	jmp	.done

.disk_err:
	mov	si, msg_disk_err
	call	pstr
.done:
	mov	ax, 0x4C00
	int	0x21

; ============================================================================
; show_current_label — Display volume label for drive
; ============================================================================
show_current_label:
	call	read_rootdir
	jc	.scl_none
	call	find_label
	jc	.scl_none
	; DI points to label entry
	mov	si, msg_vol_is
	call	pstr
	mov	cx, 11
.scl_print:
	mov	al, [di]
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	inc	di
	dec	cx
	jnz	.scl_print
	call	crlf
	ret
.scl_none:
	mov	si, msg_vol_none
	call	pstr
	ret

; ============================================================================
; find_label — Find volume label entry in sector_buf
; Returns: CF=0 found (DI=entry), CF=1 not found
; ============================================================================
find_label:
	mov	di, sector_buf
	mov	cx, 16
.fl_loop:
	cmp	byte [di], 0
	je	.fl_not_found
	cmp	byte [di], 0xE5
	je	.fl_next
	test	byte [di+11], 0x08
	jnz	.fl_found
.fl_next:
	add	di, 32
	dec	cx
	jnz	.fl_loop
.fl_not_found:
	stc
	ret
.fl_found:
	clc
	ret

; ============================================================================
; read_rootdir — Read first root directory sector into sector_buf
; ============================================================================
read_rootdir:
	; Read boot sector to get root dir location
	mov	bx, sector_buf + 512
	mov	ah, 0x02
	mov	al, 1
	mov	ch, 0
	mov	cl, 1
	mov	dh, 0
	mov	dl, [drive]
	int	0x13
	jc	.rrd_err
	; Parse BPB
	mov	si, sector_buf + 512
	mov	ax, [si+24]
	mov	[bpb_spt], ax
	mov	ax, [si+26]
	mov	[bpb_heads], ax
	; root_dir_sec = reserved + nfats * spf
	mov	al, [si+16]
	xor	ah, ah
	mov	bx, [si+22]
	add	bx, bx
	add	bx, [si+14]
	mov	[root_dir_sec], bx
	; Read first root dir sector
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0201
	int	0x13
.rrd_err:
	ret

; ============================================================================
; write_rootdir — Write sector_buf back to first root dir sector
; ============================================================================
write_rootdir:
	mov	bx, sector_buf
	mov	ax, [root_dir_sec]
	call	lba_to_chs
	mov	dl, [drive]
	mov	ax, 0x0301
	int	0x13
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
msg_vol_is	db	'Volume in drive is ', 0
msg_vol_none	db	'Volume has no label', 0x0D, 0x0A, 0
msg_prompt	db	'Volume label (11 chars, ENTER for none)? ', 0
msg_delete	db	'Delete current volume label (Y/N)? ', 0
msg_removed	db	'Volume label removed.', 0x0D, 0x0A, 0
msg_set		db	'Volume label set.', 0x0D, 0x0A, 0
msg_no_room	db	'No room in root directory', 0x0D, 0x0A, 0
msg_disk_err	db	'Disk error', 0x0D, 0x0A, 0

; ============================================================================
; Data
; ============================================================================
drive		db	0
have_label	db	0
new_label	times 11 db ' '
bpb_spt		dw	0
bpb_heads	dw	0
root_dir_sec	dw	0
input_buf	db	11, 0
		times 12 db 0

; Sector buffer (1024 bytes — root dir sector + boot sector)
sector_buf:
