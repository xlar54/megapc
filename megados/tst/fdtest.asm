; FDTEST.COM — File-level Disk Test via INT 21h AH=3F
; Usage: FDTEST [drive]
;   drive: A or B (default: B)
;
; Exercises the FULL DOS file-read path — the same chain Multiplan uses
; to load MP80.DAT:
;   program → AH=3F → SFT → FAT cluster chain → read_cluster_data → INT 13h
;
; Where DISKTEST validates the raw INT 13h layer, FDTEST validates
; everything DOS does on top of it: handle allocation, FAT chain walk,
; cluster-to-LBA math, seek, partial-sector/partial-cluster reads.
;
; On a freshly-formatted 360K disk, the test file (100 KB) is allocated
; contiguously starting at cluster 2, so cluster 99 of our file == cluster
; 99 of the disk == CHS 11/0/9 (LBA 206). That's exactly the sector where
; MP80.DAT cluster 99 fails for Multiplan. If the bug shows up at the
; DOS layer, it should show up here.
;
; Pattern (per byte at file offset O, with nonce from BIOS tick count):
;   byte[O] = (O_lo + O_hi + nonce_lo + nonce_hi) & 0xFF
; Stateless, offset-derived, re-verifiable without holding the whole
; file in memory. Nonce defeats stale-disk false passes.
;
; Phases:
;   Phase 1: Create B:\FDTEST.DAT, write 100 KB of pattern
;   Phase 2: Read back in 1024-byte chunks (1 cluster each)
;   Phase 3: Read back in 512-byte chunks (1 sector each)
;   Phase 4: Read back in 2048-byte chunks (cross-cluster)
;   Phase 5: Seek + 1-byte read at 16 fixed probe offsets (table at end)
;   Phase 6: Delete the test file

	cpu	8086
	org	0x0100

	cld
	push	cs
	pop	ds
	push	cs
	pop	es

	; Parse command line for drive letter at PSP:0081
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
	je	.drive_a
	cmp	al, 'B'
	je	.drive_b
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

.drive_a:
	mov	byte [drive_byte], 'A'
	jmp	.have_drive
.drive_b:
	mov	byte [drive_byte], 'B'
	jmp	.have_drive
.use_default:
	mov	byte [drive_byte], 'B'

.have_drive:
	; Patch filename with drive letter
	mov	al, [drive_byte]
	mov	[fname], al
	mov	[fname_ro], al

	; Banner
	mov	si, msg_banner
	call	pstr
	mov	dl, [drive_byte]
	mov	ah, 0x02
	int	0x21
	call	nl

	; Nonce from BIOS tick counter
	xor	ax, ax
	int	0x1A
	push	cs
	pop	ds
	mov	[nonce], dx
	mov	si, msg_nonce
	call	pstr
	mov	ax, [nonce]
	call	phex
	call	nl

	; Initialize counters
	xor	ax, ax
	mov	[fail_count], ax
	mov	[write_errs], ax
	mov	[read_errs], ax
	mov	[data_errs], ax
	mov	[bytes_ok], ax
	mov	[bytes_ok+2], ax

	; Destroy any existing test file first (ignore error)
	mov	ah, 0x41		; delete
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds

	; =========================================================
	; PHASE 1 — Create + write 100 KB of pattern
	; =========================================================
	mov	si, msg_phase1
	call	pstr

	; Create file (AH=3C), CX=0 (normal attrs)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds
	jnc	.p1_open_ok
	mov	si, msg_create_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21
.p1_open_ok:
	mov	[handle], ax

	; Write TOTAL_BYTES bytes in WRITE_CHUNK-byte chunks
	xor	ax, ax
	mov	[file_ofs], ax
	mov	[file_ofs+2], ax

.p1_w_loop:
	; Check if we've hit TOTAL_BYTES
	mov	ax, [file_ofs+2]
	cmp	ax, TOTAL_HI
	jb	.p1_w_go
	ja	.p1_w_done
	mov	ax, [file_ofs]
	cmp	ax, TOTAL_LO
	jae	.p1_w_done

.p1_w_go:
	; Fill buf with pattern for current file_ofs
	call	fill_pattern_chunk

	; Write WRITE_CHUNK bytes
	mov	ah, 0x40
	mov	bx, [handle]
	mov	cx, WRITE_CHUNK
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	jc	.p1_w_err
	cmp	ax, WRITE_CHUNK
	jne	.p1_w_err

	; Advance file_ofs by WRITE_CHUNK
	add	word [file_ofs], WRITE_CHUNK
	adc	word [file_ofs+2], 0

	; Progress dot every 8 KB
	mov	ax, [file_ofs]
	and	ax, 0x1FFF
	jnz	.p1_w_cont
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	push	cs			; RELOAD DS — INT 21h AH=02 may clobber
	pop	ds
.p1_w_cont:
	jmp	.p1_w_loop

.p1_w_err:
	inc	word [write_errs]
	mov	si, msg_write_err
	call	pstr
	jmp	.p1_w_done

.p1_w_done:
	; Close file
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds
	call	nl

	; If any write errors, skip the rest
	cmp	word [write_errs], 0
	je	.p2_start
	jmp	.report


	; =========================================================
	; PHASE 2 — Read in 1024-byte chunks (1 cluster each)
	; =========================================================
.p2_start:
	mov	si, msg_phase2
	call	pstr
	mov	cx, 1024
	call	read_verify_phase
	call	nl

	; =========================================================
	; PHASE 3 — Read in 512-byte chunks (1 sector each)
	; =========================================================
	mov	si, msg_phase3
	call	pstr
	mov	cx, 512
	call	read_verify_phase
	call	nl

	; =========================================================
	; PHASE 4 — Read in 2048-byte chunks (cross-cluster)
	; =========================================================
	mov	si, msg_phase4
	call	pstr
	mov	cx, 2048
	call	read_verify_phase
	call	nl

	; =========================================================
	; PHASE 5 — Seek + 1-byte read at a set of probe offsets
	; =========================================================
	mov	si, msg_phase5
	call	pstr

	mov	ah, 0x3D
	mov	al, 0
	mov	dx, fname_ro
	int	0x21
	push	cs
	pop	ds
	jc	.p5_open_err
	mov	[handle], ax

	mov	si, probe_offsets
	mov	cx, PROBE_COUNT
.p5_loop:
	push	cx
	push	si

	; Load 32-bit offset into CX:DX
	mov	dx, [si]
	mov	cx, [si+2]
	mov	[file_ofs], dx
	mov	[file_ofs+2], cx

	; AH=42 lseek, AL=0 (from start)
	mov	ah, 0x42
	mov	al, 0
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds
	jc	.p5_seek_err

	; Read 1 byte
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 1
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	jc	.p5_read_err
	cmp	ax, 1
	jne	.p5_read_short

	; Compute expected byte for file_ofs
	call	expected_byte		; returns expected in AL
	cmp	al, [buf]
	jne	.p5_data_err
	jmp	.p5_ok

.p5_seek_err:
.p5_read_err:
.p5_read_short:
	inc	word [read_errs]
	call	log_read_fail
	jmp	.p5_ok
.p5_data_err:
	inc	word [data_errs]
	call	log_data_fail
.p5_ok:
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	push	cs			; RELOAD DS — INT 21h AH=02 may clobber
	pop	ds

	pop	si
	pop	cx
	add	si, 4
	loop	.p5_loop

	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds
	call	nl
	jmp	.p6_start

.p5_open_err:
	inc	word [read_errs]
	mov	si, msg_open_err
	call	pstr


	; =========================================================
	; PHASE 6 — Delete the test file
	; =========================================================
.p6_start:
	mov	si, msg_phase6
	call	pstr
	mov	ah, 0x41
	mov	dx, fname
	int	0x21
	push	cs
	pop	ds
	jc	.p6_err
	mov	si, msg_ok
	call	pstr
	jmp	.p6_done
.p6_err:
	mov	si, msg_fail
	call	pstr
.p6_done:
	call	nl


	; =========================================================
	; REPORT
	; =========================================================
.report:
	call	nl
	mov	si, msg_summary
	call	pstr

	mov	si, msg_sum_size
	call	pstr
	mov	ax, TOTAL_HI
	call	phex
	mov	ax, TOTAL_LO
	call	phex
	mov	si, msg_bytes
	call	pstr
	call	nl

	mov	si, msg_sum_werr
	call	pstr
	mov	ax, [write_errs]
	call	pdec
	call	nl

	mov	si, msg_sum_rerr
	call	pstr
	mov	ax, [read_errs]
	call	pdec
	call	nl

	mov	si, msg_sum_derr
	call	pstr
	mov	ax, [data_errs]
	call	pdec
	call	nl

	call	nl

	; If any failures, print up to MAX_FAILS log entries
	cmp	word [fail_count], 0
	je	.allgood
	mov	si, msg_failures
	call	pstr
	mov	cx, [fail_count]
	cmp	cx, MAX_FAILS
	jbe	.flog_cap_ok
	mov	cx, MAX_FAILS
.flog_cap_ok:
	mov	bx, fail_log
.flog_loop:
	push	cx
	; Each entry: 1 byte code + 4 byte offset + 1 byte expected + 1 byte actual = 7 bytes
	mov	al, [bx]
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	si, msg_lbl_ofs
	call	pstr
	mov	ax, [bx+3]
	call	phex
	mov	ax, [bx+1]
	call	phex
	mov	al, [bx]
	cmp	al, 'D'
	jne	.flog_next
	mov	si, msg_lbl_exp
	call	pstr
	mov	al, [bx+5]
	xor	ah, ah
	call	phex_al
	mov	si, msg_lbl_got
	call	pstr
	mov	al, [bx+6]
	xor	ah, ah
	call	phex_al
.flog_next:
	call	nl
	add	bx, 7
	pop	cx
	loop	.flog_loop

	mov	ax, [fail_count]
	cmp	ax, MAX_FAILS
	jbe	.all_shown
	sub	ax, MAX_FAILS
	mov	si, msg_more
	call	pstr
	call	pdec
	mov	si, msg_more_end
	call	pstr
.all_shown:
	call	nl
	mov	si, msg_fail
	call	pstr
	call	nl
	mov	ax, 0x4C01
	int	0x21

.allgood:
	mov	si, msg_pass
	call	pstr
	call	nl
	mov	ax, 0x4C00
	int	0x21


; ============================================================================
; Subroutines
; ============================================================================

; read_verify_phase — open file, read entire file in CX-byte chunks, verify.
; Input: CX = chunk size
; Reinitializes file_ofs.
read_verify_phase:
	push	cx
	push	cs
	pop	ds

	; Save chunk size
	mov	[chunk_size], cx

	mov	ah, 0x3D
	mov	al, 0			; read only
	mov	dx, fname_ro
	int	0x21
	push	cs
	pop	ds
	jc	.rvp_open_err
	mov	[handle], ax

	xor	ax, ax
	mov	[file_ofs], ax
	mov	[file_ofs+2], ax

.rvp_loop:
	; Remaining bytes = TOTAL - file_ofs
	mov	ax, TOTAL_LO
	sub	ax, [file_ofs]
	mov	dx, TOTAL_HI
	sbb	dx, [file_ofs+2]
	mov	bx, dx
	or	bx, ax
	jz	.rvp_done		; 0 bytes left

	; If remaining < chunk, use remaining (but for our 100K/aligned
	; chunks this never happens).
	mov	cx, [chunk_size]
	cmp	dx, 0
	jne	.rvp_use_chunk
	cmp	ax, cx
	jae	.rvp_use_chunk
	mov	cx, ax
.rvp_use_chunk:

	; Read CX bytes
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	dx, buf
	int	0x21
	push	cs
	pop	ds
	jc	.rvp_read_err
	cmp	ax, [chunk_size]
	jne	.rvp_short

	; Verify buf[0..chunk_size-1]
	mov	cx, [chunk_size]
	call	verify_buf_bytes

	; Advance file_ofs by chunk_size
	mov	ax, [chunk_size]
	add	[file_ofs], ax
	adc	word [file_ofs+2], 0

	; Progress dot every 8 KB
	test	word [file_ofs], 0x1FFF
	jnz	.rvp_loop
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	push	cs			; RELOAD DS — INT 21h AH=02 may clobber
	pop	ds
	jmp	.rvp_loop

.rvp_read_err:
	inc	word [read_errs]
	call	log_read_fail
	jmp	.rvp_done
.rvp_short:
	inc	word [read_errs]
	call	log_read_fail
	jmp	.rvp_done

.rvp_open_err:
	inc	word [read_errs]
	mov	si, msg_open_err
	call	pstr
	pop	cx
	ret

.rvp_done:
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21
	push	cs
	pop	ds
	pop	cx
	ret

; fill_pattern_chunk — fill buf with WRITE_CHUNK bytes starting at file_ofs
fill_pattern_chunk:
	push	ax
	push	bx
	push	cx
	push	di
	mov	di, buf
	mov	cx, WRITE_CHUNK
	mov	bx, 0			; byte counter within chunk
.fpc_loop:
	push	cx
	push	bx
	mov	ax, bx
	add	ax, [file_ofs]
	mov	dx, [file_ofs+2]	; dx:ax = absolute offset (low 32-bit; dx unused here)
	; expected = (ax_lo + ax_hi + nonce_lo + nonce_hi) & 0xFF
	call	pattern_byte		; input: AX = offset low word, returns AL=expected
	mov	[di], al
	inc	di
	pop	bx
	pop	cx
	inc	bx
	dec	cx
	jnz	.fpc_loop
	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret

; pattern_byte — compute expected byte given AX = offset low word.
; For a 100 KB file, offset_high is 0 or 1; we factor in offset_high by
; passing it via DX externally. Simpler form: include [file_ofs+2] and
; the whole 32-bit offset by reconstructing inside. We take a shortcut
; assuming the caller handles the high word.
; Implementation: AL = (ax_lo + ax_hi + nonce_lo + nonce_hi + ofs_hi) & 0xFF
; where ofs_hi is [file_ofs+2] low byte (only bits 0-1 used for 100KB).
pattern_byte:
	push	dx
	push	bx
	mov	bl, al		; ax_lo
	add	bl, ah		; + ax_hi
	mov	al, [nonce]
	add	bl, al
	mov	al, [nonce+1]
	add	bl, al
	mov	al, [file_ofs+2]
	add	bl, al
	mov	al, bl
	pop	bx
	pop	dx
	ret

; expected_byte — compute expected byte for full 32-bit file_ofs
;   AL = (ofs[0]+ofs[1]+ofs[2]+ofs[3]+nonce_lo+nonce_hi) & 0xFF
expected_byte:
	push	bx
	mov	bl, [file_ofs]
	add	bl, [file_ofs+1]
	add	bl, [file_ofs+2]
	add	bl, [file_ofs+3]
	add	bl, [nonce]
	add	bl, [nonce+1]
	mov	al, bl
	pop	bx
	ret

; verify_buf_bytes — verify buf[0..CX-1] against pattern starting at file_ofs
; Input: CX = byte count (preserved on return)
verify_buf_bytes:
	push	ax
	push	bx
	push	cx
	push	si
	mov	si, buf
	mov	bx, 0			; relative index within buf
.vbb_loop:
	; Compute expected for (file_ofs + bx)
	push	cx
	push	bx

	; Re-derive expected using full 32-bit offset (file_ofs) + bx
	; Temporarily adjust file_ofs by bx for expected_byte
	mov	ax, [file_ofs]
	add	ax, bx
	mov	dx, [file_ofs+2]
	adc	dx, 0
	push	word [file_ofs]
	push	word [file_ofs+2]
	mov	[file_ofs], ax
	mov	[file_ofs+2], dx
	call	expected_byte		; AL = expected
	mov	ah, [si]
	cmp	al, ah
	je	.vbb_ok_restore
	; Data mismatch — log with file_ofs still at the mismatch offset
	inc	word [data_errs]
	push	ax			; save expected in AL, got in AH
	call	log_data_fail_at
	pop	ax
.vbb_ok_restore:
	pop	word [file_ofs+2]
	pop	word [file_ofs]
.vbb_ok:
	pop	bx
	pop	cx
	inc	si
	inc	bx
	dec	cx
	jnz	.vbb_loop

	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; log_read_fail — log a read failure at current file_ofs
log_read_fail:
	push	ax
	push	bx
	push	cx
	push	di

	mov	cx, [fail_count]
	inc	word [fail_count]
	cmp	cx, MAX_FAILS
	jae	.lrf_done

	; Entry address: fail_log + cx*7
	mov	ax, cx
	mov	bx, 7
	mul	bx
	mov	di, ax
	add	di, fail_log

	mov	byte [di], 'R'
	mov	ax, [file_ofs]
	mov	[di+1], ax
	mov	ax, [file_ofs+2]
	mov	[di+3], ax
	mov	byte [di+5], 0
	mov	byte [di+6], 0
.lrf_done:
	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret

; log_data_fail — log a simple data mismatch at current file_ofs (AH=got in AH from caller)
; Used only by phase 5 (1-byte reads).
log_data_fail:
	push	ax
	push	bx
	push	cx
	push	di

	mov	cx, [fail_count]
	inc	word [fail_count]
	cmp	cx, MAX_FAILS
	jae	.ldf_done

	mov	ax, cx
	mov	bx, 7
	mul	bx
	mov	di, ax
	add	di, fail_log

	mov	byte [di], 'D'
	mov	ax, [file_ofs]
	mov	[di+1], ax
	mov	ax, [file_ofs+2]
	mov	[di+3], ax
	call	expected_byte		; AL=expected
	mov	[di+5], al
	mov	al, [buf]
	mov	[di+6], al
.ldf_done:
	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret

; log_data_fail_at — log mismatch at file_ofs + bx (bx = relative idx)
; Input: AL=expected, AH=got
log_data_fail_at:
	push	ax
	push	bx
	push	cx
	push	di

	mov	[tmp_exp], al
	mov	[tmp_got], ah

	mov	cx, [fail_count]
	inc	word [fail_count]
	cmp	cx, MAX_FAILS
	jae	.ldfa_done

	mov	ax, cx
	mov	bx, 7
	mul	bx
	mov	di, ax
	add	di, fail_log

	mov	byte [di], 'D'
	; Absolute offset = file_ofs + bx (caller's BX was pushed — we need to peek)
	; Simpler: re-fetch from caller-side stack... too messy.
	; Use file_ofs directly (bx was added before expected_byte was adjusted back)
	mov	ax, [file_ofs]
	mov	[di+1], ax
	mov	ax, [file_ofs+2]
	mov	[di+3], ax
	mov	al, [tmp_exp]
	mov	[di+5], al
	mov	al, [tmp_got]
	mov	[di+6], al
.ldfa_done:
	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret

; ==========================
; Print helpers
; ==========================

pstr:
	push	ax
	push	dx
	cld
.ps_loop:
	lodsb
	or	al, al
	jz	.ps_done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	jmp	.ps_loop
.ps_done:
	pop	dx
	pop	ax
	ret

nl:
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

; phex — print AX as 4 hex digits
phex:
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
	jbe	.ph_o
	add	al, 7
.ph_o:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph_loop
	pop	dx
	pop	cx
	pop	ax
	ret

; phex_al — print AL as 2 hex digits
phex_al:
	push	ax
	push	cx
	push	dx
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
	pop	dx
	pop	cx
	pop	ax
	ret

pdec:
	push	ax
	push	bx
	push	cx
	push	dx
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
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret


; ============================================================================
; Data
; ============================================================================

; 100 KB file size — guarantees the test file spans cluster 99 (LBA 206 =
; CHS 11/0/9 on 360K), i.e., MP80.DAT's failing sector.
; 102400 = 0x19000, so TOTAL_HI = 1 and TOTAL_LO = 0x9000.
TOTAL_LO	equ	0x9000
TOTAL_HI	equ	0x0001
WRITE_CHUNK	equ	1024
MAX_FAILS	equ	16
PROBE_COUNT	equ	16

msg_usage	db	'Usage: FDTEST [A|B]', 0x0D, 0x0A, 0
msg_banner	db	'FDTEST - drive ', 0
msg_nonce	db	'  nonce=$', 0
msg_create_err	db	0x0D, 0x0A, 'Create failed.', 0x0D, 0x0A, 0
msg_open_err	db	'Open failed. ', 0
msg_write_err	db	'!', 0
msg_phase1	db	0x0D, 0x0A, 'Phase 1 CREATE+WRITE (100K):    ', 0
msg_phase2	db	'Phase 2 READ 1K chunks:          ', 0
msg_phase3	db	'Phase 3 READ 512 chunks:         ', 0
msg_phase4	db	'Phase 4 READ 2K chunks (xclus): ', 0
msg_phase5	db	'Phase 5 SEEK+1byte probes:      ', 0
msg_phase6	db	'Phase 6 DELETE: ', 0
msg_summary	db	'=== Summary ===', 0x0D, 0x0A, 0
msg_sum_size	db	'file size:     $', 0
msg_bytes	db	' bytes', 0
msg_sum_werr	db	'write errors:  ', 0
msg_sum_rerr	db	'read errors:   ', 0
msg_sum_derr	db	'data mismatch: ', 0
msg_failures	db	'Failures (code offset[=exp/got]):', 0x0D, 0x0A
		db	'  R=read err  D=data mismatch', 0x0D, 0x0A, 0
msg_lbl_ofs	db	'ofs=$', 0
msg_lbl_exp	db	' exp=$', 0
msg_lbl_got	db	' got=$', 0
msg_more	db	'... (', 0
msg_more_end	db	' more not shown)', 0x0D, 0x0A, 0
msg_pass	db	'*** ALL TESTS PASSED ***', 0
msg_fail	db	'*** TEST FAILED ***', 0
msg_ok		db	'OK', 0

; "?:\FDTEST.DAT" - drive letter patched at runtime
fname		db	'B:\FDTEST.DAT', 0
fname_ro	db	'B:\FDTEST.DAT', 0
drive_byte	db	'B'

handle		dw	0
nonce		dw	0
file_ofs	dd	0
chunk_size	dw	0
fail_count	dw	0
write_errs	dw	0
read_errs	dw	0
data_errs	dw	0
bytes_ok	dd	0
tmp_exp		db	0
tmp_got		db	0

; A handful of probe offsets for phase 5 — includes offsets that land
; on sector 9 of head 0 for cluster 99 (file offset 99328 on 360K SPC=2)
probe_offsets:
	dd	0
	dd	1
	dd	511
	dd	512
	dd	1023
	dd	1024
	dd	99328		; first byte of cluster 99 = CHS 11/0/9 = LBA 206
	dd	99839		; last byte of cluster 99 first sector
	dd	99840		; first byte of cluster 99 second sector (LBA 207)
	dd	100351		; last byte of cluster 99
	dd	65535
	dd	65536
	dd	81920
	dd	90000
	dd	100000
	dd	102399		; last byte of file

; fail log entries: 1 code + 4 offset + 1 exp + 1 got = 7 bytes each
fail_log	times MAX_FAILS*7 db 0

	align 16
buf		times 2048 db 0
