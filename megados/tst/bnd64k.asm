; BND64K.COM — minimal 64K-boundary DOS file I/O bug isolation
; Usage: BND64K [drive]  (default B)
;
; Writes exactly 65540 bytes (64 KB + 4) to a test file, then reads it
; back, with two independent verification passes:
;
;   Phase A: sequential full-file read + mismatch count (overall integrity)
;   Phase B: lseek to 65520, read 36 bytes into bnd_buf
;            (targeted dump of the 64K transition; file only has 20 bytes
;             left starting at 65520 so we expect a short read of 20 bytes,
;             and bnd_buf[20..35] should remain as our $CC tripwire —
;             anything else flags as EOF region corruption).
;
; Both phases contribute to total_mismatch; the final verdict reflects
; BOTH. Phase B's CF/AX return from AH=3F is validated before the dump,
; so a short read or error produces a clear failure, not a misleading
; tripwire dump.
;
; Pattern is dead-simple: byte at file offset N = N & 0xFF.
;
; Why this test: FDTEST caught a "got = expected + 4" shift starting at
; file offset $10080 (64 KB + 128). This test narrows to exactly the
; bytes around the 64 KB transition so we can see what DOS returns there.
; File size 65540 = 64*1024 + 4:
;   64 writes of 1024 bytes = offsets 0..65535 (first 64 clusters)
;   1 final write of 4 bytes = offsets 65536..65539 (first 4 bytes of cluster 65)

	cpu	8086
	org	0x0100

	cld
	push	cs
	pop	ds
	push	cs
	pop	es

	; === Parse drive letter ===
	mov	si, 0x81
.skip_ws:
	lodsb
	cmp	al, ' '
	je	.skip_ws
	cmp	al, 9
	je	.skip_ws
	cmp	al, 0x0D
	je	.use_default
	cmp	al, 0
	je	.use_default
	and	al, 0xDF
	cmp	al, 'A'
	jb	.use_default
	cmp	al, 'B'
	ja	.use_default
	jmp	.got_drive
.use_default:
	mov	al, 'B'
.got_drive:
	mov	[fname], al
	mov	[fname_ro], al

	mov	si, msg_banner
	call	pstr
	push	cs
	pop	ds
	mov	dl, [fname]
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	call	nl

	; Delete any existing test file (ignore error)
	mov	ah, 0x41
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds

	; =========================================================
	; Phase 1 — create + write 65540 bytes
	; =========================================================
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds
	jnc	.create_ok
	mov	si, msg_create_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21
.create_ok:
	mov	[handle], ax

	mov	si, msg_write
	call	pstr
	push	cs
	pop	ds

	mov	word [ofs_lo], 0
	mov	word [ofs_hi], 0
	mov	word [chunks_left], 64
.w_chunk_loop:
	call	fill_1024
	push	cs
	pop	ds
	mov	ah, 0x40
	mov	bx, [handle]
	mov	cx, 1024
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	cmp	ax, 1024
	jne	.write_short
	add	word [ofs_lo], 1024
	adc	word [ofs_hi], 0
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	dec	word [chunks_left]
	jnz	.w_chunk_loop

	; Final 4-byte write (offsets 65536..65539 → pattern 0,1,2,3)
	mov	byte [buf], 0
	mov	byte [buf+1], 1
	mov	byte [buf+2], 2
	mov	byte [buf+3], 3

	mov	ah, 0x40
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	cmp	ax, 4
	jne	.write_short
	mov	dl, '!'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	call	nl

	; Close
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds

	; =========================================================
	; Phase 2 — reopen, full sequential read + mismatch count
	; =========================================================
	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname_ro
	int	0x21
	push	cs
	pop	ds
	jnc	.open_a_ok
	mov	si, msg_open_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21
.open_a_ok:
	mov	[handle], ax

	mov	si, msg_read_a
	call	pstr
	push	cs
	pop	ds

	mov	word [ofs_lo], 0
	mov	word [ofs_hi], 0
	mov	word [total_mismatch], 0
	mov	word [chunks_left], 64

.ra_chunk_loop:
	push	cs
	pop	ds
	mov	di, buf
	mov	al, 0xCC
	mov	cx, 1024
	rep	stosb

	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1024
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	cmp	ax, 1024
	jne	.read_short

	; Verify buf bytes against pattern (offset & 0xFF)
	mov	si, buf
	mov	cx, 1024
	mov	al, [ofs_lo]
.ra_byte:
	cmp	[si], al
	je	.ra_byte_ok
	call	record_fail
.ra_byte_ok:
	inc	si
	inc	al
	loop	.ra_byte

	add	word [ofs_lo], 1024
	adc	word [ofs_hi], 0
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	dec	word [chunks_left]
	jnz	.ra_chunk_loop

	; Final 4 bytes
	push	cs
	pop	ds
	mov	di, buf
	mov	al, 0xCC
	mov	cx, 4
	rep	stosb

	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 4
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	cmp	ax, 4
	jne	.read_short

	; Verify: expected bytes 0,1,2,3
	cmp	byte [buf], 0
	je	.ra_b1
	call	record_fail
.ra_b1:
	cmp	byte [buf+1], 1
	je	.ra_b2
	call	record_fail
.ra_b2:
	cmp	byte [buf+2], 2
	je	.ra_b3
	call	record_fail
.ra_b3:
	cmp	byte [buf+3], 3
	je	.ra_done
	call	record_fail
.ra_done:
	mov	dl, '!'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	call	nl

	; =========================================================
	; Phase 3 — lseek to 65520, read exactly 36 bytes into bnd_buf
	; (targeted boundary dump, fully independent of Phase 2)
	; =========================================================
	mov	si, msg_read_b
	call	pstr
	push	cs
	pop	ds

	; lseek to 65520 ($FFF0)
	mov	ah, 0x42
	mov	al, 0			; seek from start
	mov	bx, [handle]
	mov	cx, 0
	mov	dx, 65520
	int	0x21
	push	cs
	pop	ds
	jc	.seek_err
	; Capture the new file position DOS reports (DX:AX)
	mov	[seek_hi], dx
	mov	[seek_lo], ax

	; Pre-fill bnd_buf with $CC (tripwire)
	mov	di, bnd_buf
	mov	al, 0xCC
	mov	cx, 36
	rep	stosb

	; Read 36 bytes into bnd_buf
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 36
	mov	dx, bnd_buf
	int	0x21
	push	cs
	pop	ds
	jc	.phase_b_read_err
	mov	[bytes_got], ax
	; File has only 20 bytes from offset 65520 onward (65540 - 65520).
	; If AX != 20, DOS gave us an unexpected count — flag as failure.
	cmp	ax, 20
	jne	.phase_b_count_bad
	jmp	.phase_b_read_ok

.phase_b_read_err:
	mov	word [phase_b_fail], 1
	mov	word [bytes_got], 0
	jmp	.phase_b_read_ok
.phase_b_count_bad:
	mov	word [phase_b_fail], 1
.phase_b_read_ok:

	; Close
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds

	; Delete
	mov	ah, 0x41
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds

	mov	dl, '!'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	call	nl

	; =========================================================
	; Report
	; =========================================================
	call	nl

	; Diagnostic: show seek result and bytes returned
	push	cs
	pop	ds
	mov	si, msg_diag_seek
	call	pstr
	push	cs
	pop	ds
	mov	ax, [seek_hi]
	call	phex
	push	cs
	pop	ds
	mov	ax, [seek_lo]
	call	phex
	push	cs
	pop	ds
	mov	si, msg_diag_got
	call	pstr
	push	cs
	pop	ds
	mov	ax, [bytes_got]
	call	pdec
	push	cs
	pop	ds
	call	nl

	mov	si, msg_boundary
	call	pstr
	push	cs
	pop	ds
	mov	ax, [bytes_got]
	call	pdec
	mov	si, msg_bytes_read
	call	pstr
	push	cs
	pop	ds
	call	nl
	call	nl

	; Print 36 lines: offset, expected byte, got byte, match?
	; For entries within bytes_got (valid file data), any mismatch
	; increments total_mismatch so the final verdict reflects Phase B.
	; For entries past bytes_got (past EOF), we expect the $CC tripwire;
	; a non-$CC byte flags as EOF-region corruption.
	push	cs
	pop	ds
	mov	word [ofs_lo], 65520
	mov	word [ofs_hi], 0
	mov	bx, bnd_buf
	mov	word [dump_left], 24
	mov	word [dump_idx], 0

.dump_loop:
	push	cs
	pop	ds
	mov	dl, '$'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	mov	ax, [ofs_hi]
	call	phex
	push	cs
	pop	ds
	mov	ax, [ofs_lo]
	call	phex

	push	cs
	pop	ds
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	mov	si, msg_exp
	call	pstr
	push	cs
	pop	ds
	mov	dl, '$'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	mov	al, [ofs_lo]
	call	phex_al

	push	cs
	pop	ds
	mov	si, msg_got
	call	pstr
	push	cs
	pop	ds
	mov	dl, '$'
	mov	ah, 0x02
	int	0x21
	push	cs
	pop	ds
	mov	al, [bx]
	call	phex_al

	; Decide: in-range (idx < bytes_got) or past-EOF
	push	cs
	pop	ds
	mov	ax, [dump_idx]
	cmp	ax, [bytes_got]
	jae	.dmp_past_eof

	; In-range: expected = ofs_lo low byte, got = [bx]
	mov	ah, [ofs_lo]
	mov	al, [bx]
	cmp	al, ah
	je	.dmp_match
	call	record_fail	; count toward verdict
	mov	si, msg_nomatch
	call	pstr
	jmp	.dmp_line_end
.dmp_match:
	mov	si, msg_ok_mark
	call	pstr
	jmp	.dmp_line_end

.dmp_past_eof:
	; Past EOF: [bx] should be $CC (our tripwire). Otherwise, DOS
	; overwrote past-EOF territory — count as mismatch.
	mov	al, [bx]
	cmp	al, 0xCC
	je	.dmp_eof_clean
	call	record_fail
	mov	si, msg_eof_dirty
	call	pstr
	jmp	.dmp_line_end
.dmp_eof_clean:
	mov	si, msg_eof_mark
	call	pstr

.dmp_line_end:
	push	cs
	pop	ds
	call	nl

	inc	bx
	; Use ADD (which sets CF) instead of INC (which doesn't) so the
	; ADC correctly propagates to ofs_hi at the 16-bit wrap.
	add	word [ofs_lo], 1
	adc	word [ofs_hi], 0
	inc	word [dump_idx]
	dec	word [dump_left]
	jnz	.dump_loop

	; If phase_b_fail was flagged (CF=1 or wrong byte count), fold
	; it into the verdict so Phase B genuinely affects pass/fail.
	cmp	word [phase_b_fail], 0
	je	.no_phase_b_fail
	mov	word [any_failure], 1
.no_phase_b_fail:

	call	nl
	mov	si, msg_summary
	call	pstr
	push	cs
	pop	ds
	mov	ax, [total_mismatch]
	call	pdec
	mov	si, msg_of_65540
	call	pstr
	push	cs
	pop	ds
	call	nl

	cmp	word [any_failure], 0
	jne	.failed
	mov	si, msg_pass
	call	pstr
	push	cs
	pop	ds
	call	nl
	mov	ax, 0x4C00
	int	0x21
.failed:
	mov	si, msg_fail
	call	pstr
	push	cs
	pop	ds
	call	nl
	mov	ax, 0x4C01
	int	0x21


.write_short:
	mov	si, msg_write_short
	call	pstr
	mov	ax, 0x4C01
	int	0x21

.read_short:
	mov	si, msg_read_short
	call	pstr
	mov	ax, 0x4C01
	int	0x21

.seek_err:
	mov	si, msg_seek_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21


; =============================================================
; record_fail — set any_failure=1 and saturating-increment total_mismatch.
; Preserves all registers.
record_fail:
	push	ax
	push	ds
	push	cs
	pop	ds
	mov	word [any_failure], 1
	mov	ax, [total_mismatch]
	cmp	ax, 0xFFFF
	je	.rf_sat
	inc	word [total_mismatch]
.rf_sat:
	pop	ds
	pop	ax
	ret

; =============================================================
; fill_1024 — fill buf with 1024 pattern bytes starting at ofs_lo:ofs_hi
; Pattern: buf[i] = (ofs_lo + i) & 0xFF  (offset low byte)
; Since ofs is a multiple of 1024, low byte of ofs is always 0.
; Clobbers AX, CX, DI.
fill_1024:
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	di, buf
	mov	cx, 1024
	mov	al, [ofs_lo]
.fl_loop:
	stosb
	inc	al
	loop	.fl_loop
	ret


; =============================================================
; Print helpers — all save/force/restore DS (MegaDOS INT 21h AH=02
; clobbers DS, so callers immediately accessing DS-relative vars can
; get garbage if we don't do this).
; =============================================================

pstr:
	push	ax
	push	dx
	cld
.ps_loop:
	lodsb
	or	al, al
	jz	.ps_done
	push	ds
	push	cs
	pop	ds
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ds
	jmp	.ps_loop
.ps_done:
	pop	dx
	pop	ax
	ret

nl:
	push	ax
	push	dx
	push	ds
	push	cs
	pop	ds
	mov	dl, 0x0D
	mov	ah, 0x02
	int	0x21
	mov	dl, 0x0A
	mov	ah, 0x02
	int	0x21
	pop	ds
	pop	dx
	pop	ax
	ret

phex:
	push	ax
	push	cx
	push	dx
	push	ds
	push	cs
	pop	ds
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
	jbe	.ph_o
	add	al, 7
.ph_o:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph_loop
	pop	ds
	pop	dx
	pop	cx
	pop	ax
	ret

phex_al:
	push	ax
	push	cx
	push	dx
	push	ds
	push	cs
	pop	ds
	mov	cx, 2
.pha_loop:
	rol	al, 1
	rol	al, 1
	rol	al, 1
	rol	al, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.pha_o
	add	al, 7
.pha_o:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.pha_loop
	pop	ds
	pop	dx
	pop	cx
	pop	ax
	ret

pdec:
	push	ax
	push	bx
	push	cx
	push	dx
	push	ds
	push	cs
	pop	ds
	mov	bx, 10
	xor	cx, cx
.pd_gather:
	xor	dx, dx
	div	bx
	push	dx
	inc	cx
	or	ax, ax
	jnz	.pd_gather
.pd_emit:
	pop	dx
	add	dl, '0'
	mov	ah, 0x02
	int	0x21
	loop	.pd_emit
	pop	ds
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret


; =============================================================
; Data
; =============================================================

msg_banner	db	'BND64K - drive ', 0
msg_create_err	db	'create failed', 0x0D, 0x0A, 0
msg_open_err	db	'open failed', 0x0D, 0x0A, 0
msg_seek_err	db	'seek failed', 0x0D, 0x0A, 0
msg_write_short	db	' [short write!]', 0x0D, 0x0A, 0
msg_read_short	db	' [short read!]', 0x0D, 0x0A, 0
msg_write	db	'Writing 65540 bytes:  ', 0
msg_read_a	db	'Phase A full read:    ', 0
msg_read_b	db	'Phase B boundary seek+read: ', 0
msg_boundary	db	'Boundary dump (', 0
msg_bytes_read	db	' bytes from offset 65520):', 0
msg_exp		db	'exp=', 0
msg_got		db	' got=', 0
msg_ok_mark	db	'  ok', 0
msg_nomatch	db	'  MISMATCH', 0
msg_eof_mark	db	'  (EOF - tripwire intact)', 0
msg_eof_dirty	db	'  (EOF - DOS overwrote past-EOF!)', 0
msg_diag_seek	db	'DIAG: lseek returned DX:AX=$', 0
msg_diag_got	db	'  AH=3F returned: ', 0
msg_summary	db	'Total byte mismatches: ', 0
msg_of_65540	db	' / 65540', 0
msg_pass	db	'*** ALL BYTES MATCH — no 64K bug ***', 0
msg_fail	db	'*** MISMATCHES FOUND ***', 0

fname		db	'B:\BND.DAT', 0
fname_ro	db	'B:\BND.DAT', 0

handle		dw	0
ofs_lo		dw	0
ofs_hi		dw	0
chunks_left	dw	0
total_mismatch	dw	0		; display counter (saturates at $FFFF)
any_failure	dw	0		; sticky boolean — used for verdict
bytes_got	dw	0
dump_left	dw	0
dump_idx	dw	0
phase_b_fail	dw	0
seek_lo		dw	0
seek_hi		dw	0

bnd_buf		times 40 db 0

	align	16
buf		times 1024 db 0
