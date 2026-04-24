; DISKTEST.COM — exhaustive floppy sector read/write verify
; Usage: DISKTEST [drive]
;   drive: A or B (default: B)
;
; For every LBA on the specified drive:
;   1. WRITE pass: fill sector with a unique pattern derived from LBA,
;      write via INT 13h AH=03, check CF.
;   2. READ pass: pre-fill buffer with $CC (tripwire), read sector via
;      INT 13h AH=02, check CF. If all $CC remain, read silently failed.
;   3. VERIFY: compare read-back bytes to expected pattern. Mismatches
;      indicate either a silent write failure or a wrong-sector read.
;
; Pattern layout for LBA N (512 bytes):
;   [0..1]  = $BEEF            ; magic signature (LE)
;   [2..3]  = N                ; LBA (LE)
;   [4..5]  = ~N               ; NOT LBA (LE, catches stuck bits)
;   [6..7]  = N                ; LBA again
;   [8..509]= (N + off) & $FF  ; walking byte pattern
;   [510..511] = $ED $FE       ; end marker
;
; WARNING: this test destroys all data on the target drive.

	cpu	8086
	org	0x0100

	cld					; ensure string ops go forward
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
	; Got a drive letter
	and	al, 0xDF		; upper-case
	cmp	al, 'A'
	je	.drive_a
	cmp	al, 'B'
	je	.drive_b
	; Unknown — show usage
	mov	si, msg_usage
	call	pstr
	mov	ax, 0x4C01
	int	0x21

.drive_a:
	mov	byte [drive], 0
	jmp	.have_drive
.drive_b:
	mov	byte [drive], 1
	jmp	.have_drive
.use_default:
	mov	byte [drive], 1		; default = drive B

.have_drive:
	; Print banner
	mov	si, msg_banner
	call	pstr
	mov	al, [drive]
	add	al, 'A'
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	call	nl

	; === Get drive geometry via INT 13h AH=08 ===
	;   CH = max_cyl (low 8 bits)
	;   CL bits 0-5 = SPT, bits 6-7 = max_cyl high bits
	;   DH = max_head
	; Floppies have <256 cyl so we ignore the high bits.
	mov	ah, 0x08
	mov	dl, [drive]
	int	0x13
	push	cs			; RELOAD DS — BIOS may clobber
	pop	ds
	jnc	.geom_ok
	mov	si, msg_geom_err
	call	pstr
	mov	ax, 0x4C01
	int	0x21
.geom_ok:
	mov	al, ch
	inc	al
	mov	[cyls], al
	mov	al, cl
	and	al, 0x3F
	mov	[spt], al
	mov	al, dh
	inc	al
	mov	[heads], al

	; Compute total_sectors = cyls * heads * spt (into total_sectors word)
	mov	al, [cyls]
	xor	ah, ah
	mov	bx, ax			; BX = cyls
	mov	al, [heads]
	xor	ah, ah
	mul	bx			; AX = cyls * heads
	mov	bx, ax
	mov	al, [spt]
	xor	ah, ah
	mul	bx			; AX = cyls * heads * spt (assume < 65536)
	mov	[total_sectors], ax

	; Print geometry: "  cyls=XX heads=X spt=XX total=XXXX"
	mov	si, msg_geom
	call	pstr
	mov	al, [cyls]
	xor	ah, ah
	call	pdec
	mov	si, msg_x_heads
	call	pstr
	mov	al, [heads]
	xor	ah, ah
	call	pdec
	mov	si, msg_x_spt
	call	pstr
	mov	al, [spt]
	xor	ah, ah
	call	pdec
	mov	si, msg_equal_total
	call	pstr
	mov	ax, [total_sectors]
	call	pdec
	mov	si, msg_sectors
	call	pstr
	call	nl

	; === Confirm ===
	mov	si, msg_warn
	call	pstr
	mov	ah, 0x01
	int	0x21
	push	ax
	call	nl
	pop	ax
	and	al, 0xDF		; upper-case
	cmp	al, 'Y'
	je	.go
	mov	si, msg_aborted
	call	pstr
	mov	ax, 0x4C00
	int	0x21

.go:
	; Initialize failure log
	mov	word [fail_count], 0
	mov	word [write_errs], 0
	mov	word [read_errs], 0
	mov	word [data_errs], 0

	; === Generate per-run nonce from BIOS tick counter ===
	; Using INT 1Ah AH=00 (Get Tick Count). CX:DX = tick count.
	; Low word (DX) is plenty of entropy for distinguishing runs —
	; the pattern becomes LBA XOR nonce, so previously-patterned
	; sectors from an earlier run won't pass verification by accident.
	xor	ax, ax
	int	0x1A
	push	cs
	pop	ds			; defensive: INT 1Ah may clobber DS
	mov	[nonce], dx

	; Print nonce so the run is self-identifying
	mov	si, msg_nonce
	call	pstr
	mov	ax, [nonce]
	call	phex
	call	nl

	; === PHASE 1: WRITE ===
	mov	si, msg_phase1
	call	pstr
	mov	word [cur_lba], 0
.w_loop:
	push	cs			; RELOAD DS each iteration — INT 13h/21h may clobber
	pop	ds
	mov	ax, [cur_lba]
	cmp	ax, [total_sectors]
	jae	.w_done
	call	fill_pattern		; fill sector_buf with pattern for cur_lba
	call	lba_to_chs		; sets ch/cl/dh
	push	cs			; RELOAD ES — DOS calls clobber it
	pop	es
	mov	ax, 0x0301		; AH=03 (write) AL=1 sector
	mov	dl, [drive]
	mov	bx, sector_buf
	int	0x13
	push	cs			; RELOAD DS — BIOS may clobber
	pop	ds
	jnc	.w_ok
	; Write error
	inc	word [write_errs]
	mov	al, 'W'
	call	log_failure
.w_ok:
	call	progress_dot
	inc	word [cur_lba]
	jmp	.w_loop
.w_done:
	call	nl

	; === PHASE 2 + 3: READ + VERIFY ===
	mov	si, msg_phase2
	call	pstr
	mov	word [cur_lba], 0
.r_loop:
	push	cs			; RELOAD DS each iteration
	pop	ds
	mov	ax, [cur_lba]
	cmp	ax, [total_sectors]
	jae	.r_done
	; Pre-fill buffer with $CC tripwire
	call	tripwire_fill
	call	lba_to_chs
	push	cs			; RELOAD ES — DOS calls clobber it
	pop	es
	mov	ax, 0x0201		; AH=02 (read) AL=1 sector
	mov	dl, [drive]
	mov	bx, sector_buf
	int	0x13
	push	cs			; RELOAD DS — BIOS may clobber
	pop	ds
	jnc	.r_cf_ok
	; Read returned CF=1
	inc	word [read_errs]
	mov	al, 'R'
	call	log_failure
	jmp	.r_next
.r_cf_ok:
	; Check for silent failure — buffer should not be all $CC
	call	check_tripwire
	jnc	.r_data_check
	; Tripwire survived — silent failure
	inc	word [read_errs]
	mov	al, 'S'			; silent-read
	call	log_failure
	jmp	.r_next
.r_data_check:
	; Verify pattern
	call	verify_pattern
	jnc	.r_next
	; Data mismatch
	inc	word [data_errs]
	mov	al, 'D'
	call	log_failure
.r_next:
	call	progress_dot
	inc	word [cur_lba]
	jmp	.r_loop
.r_done:
	call	nl
	call	nl

	; === Report ===
	mov	si, msg_summary
	call	pstr

	mov	si, msg_sum_tested
	call	pstr
	mov	ax, [total_sectors]
	call	pdec
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

	; Print failure log (up to MAX_FAILS)
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
	; Entry = 1 byte code + word LBA + 1 byte CH + 1 byte DH + 1 byte CL = 6 bytes
	mov	al, [bx]		; code
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	mov	si, msg_lbl_lba
	call	pstr
	mov	ax, [bx+1]
	call	pdec
	mov	si, msg_lbl_chs
	call	pstr
	mov	al, [bx+3]
	xor	ah, ah
	call	pdec
	mov	dl, '/'
	mov	ah, 0x02
	int	0x21
	mov	al, [bx+4]
	xor	ah, ah
	call	pdec
	mov	dl, '/'
	mov	ah, 0x02
	int	0x21
	mov	al, [bx+5]
	xor	ah, ah
	call	pdec
	call	nl
	add	bx, 6
	pop	cx
	loop	.flog_loop

	mov	ax, [fail_count]
	cmp	ax, MAX_FAILS
	jbe	.all_shown
	sub	ax, MAX_FAILS
	push	ax
	mov	si, msg_more
	call	pstr
	pop	ax
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

; fill_pattern — fill sector_buf with pattern derived from cur_lba + nonce
;   [0..1] = $BEEF
;   [2..3] = LBA
;   [4..5] = nonce
;   [6..7] = LBA XOR nonce
;   [8..509] = ((LBA_lo XOR nonce_lo) + offset) & $FF
;   [510..511] = $FEED
; The nonce (BIOS tick count at startup) prevents stale-disk false-pass:
; a silent write of nothing won't match the pattern because the verify
; checks the current run's nonce, not a previous run's.
fill_pattern:
	push	ax
	push	bx
	push	cx
	push	di

	mov	di, sector_buf
	mov	word [di], 0xBEEF
	mov	ax, [cur_lba]
	mov	[di+2], ax
	mov	ax, [nonce]
	mov	[di+4], ax
	mov	ax, [cur_lba]
	xor	ax, [nonce]
	mov	[di+6], ax

	; Walking byte pattern: byte[8+N] = ((LBA_lo XOR nonce_lo) + N) & 0xFF
	mov	al, [cur_lba]
	xor	al, [nonce]
	mov	bx, 8
	mov	cx, 502
.fp_loop:
	mov	[sector_buf+bx], al
	inc	al
	inc	bx
	loop	.fp_loop

	mov	word [sector_buf+510], 0xFEED

	pop	di
	pop	cx
	pop	bx
	pop	ax
	ret

; tripwire_fill — fill sector_buf with $CC
tripwire_fill:
	push	ax
	push	cx
	push	di
	push	es
	push	cs
	pop	es
	cld
	mov	di, sector_buf
	mov	al, 0xCC
	mov	cx, 512
	rep	stosb
	pop	es
	pop	di
	pop	cx
	pop	ax
	ret

; check_tripwire — verify buffer is NOT all $CC (i.e., read actually happened)
; Returns CF=0 if something was written (OK), CF=1 if all $CC (silent fail)
check_tripwire:
	push	cx
	push	si
	cld
	mov	si, sector_buf
	mov	cx, 512
.ct_loop:
	lodsb
	cmp	al, 0xCC
	jne	.ct_ok
	loop	.ct_loop
	; All 512 bytes are $CC — silent failure
	stc
	pop	si
	pop	cx
	ret
.ct_ok:
	clc
	pop	si
	pop	cx
	ret

; verify_pattern — check sector_buf matches expected pattern for cur_lba
; Returns CF=0 if match, CF=1 if mismatch
verify_pattern:
	push	ax
	push	bx
	push	cx
	push	si

	mov	si, sector_buf
	; [0..1] = $BEEF
	mov	ax, [si]
	cmp	ax, 0xBEEF
	jne	.vp_fail
	; [2..3] = LBA
	mov	ax, [si+2]
	cmp	ax, [cur_lba]
	jne	.vp_fail
	; [4..5] = nonce
	mov	ax, [si+4]
	cmp	ax, [nonce]
	jne	.vp_fail
	; [6..7] = LBA XOR nonce
	mov	ax, [si+6]
	mov	bx, [cur_lba]
	xor	bx, [nonce]
	cmp	ax, bx
	jne	.vp_fail
	; [8..509] = walking byte ((LBA_lo XOR nonce_lo) + N) & $FF
	mov	al, [cur_lba]
	xor	al, [nonce]
	mov	bx, 8
	mov	cx, 502
.vp_loop:
	cmp	al, [si+bx]
	jne	.vp_fail
	inc	al
	inc	bx
	loop	.vp_loop
	; [510..511] = $FEED
	mov	ax, [si+510]
	cmp	ax, 0xFEED
	jne	.vp_fail

	clc
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret
.vp_fail:
	stc
	pop	si
	pop	cx
	pop	bx
	pop	ax
	ret

; lba_to_chs — convert cur_lba to CH/DH/CL for int 13h
; Using spt/heads variables.
;   sector   = (LBA mod SPT) + 1
;   tmp      = LBA / SPT
;   head     = tmp mod heads
;   cyl      = tmp / heads
; Clobbers: AX, BX
; Output: CH=cyl, DH=head, CL=sector (other CX/DX bits cleared)
lba_to_chs:
	mov	ax, [cur_lba]
	xor	dx, dx
	mov	bl, [spt]
	xor	bh, bh
	div	bx			; AX = LBA/SPT, DX = LBA%SPT
	mov	cl, dl
	inc	cl			; CL = sector (1-based)

	xor	dx, dx
	mov	bl, [heads]
	xor	bh, bh
	div	bx			; AX = cyl, DX = head
	mov	ch, al			; CH = cyl (floppies < 256 cyl)
	mov	dh, dl			; DH = head
	ret

; log_failure — record a failure. AL = fail code, cur_lba = LBA
; Preserves all registers.
log_failure:
	push	ax
	push	bx
	push	cx
	push	dx
	push	di
	mov	[tmp_al], al		; stash fail code

	mov	cx, [fail_count]
	inc	word [fail_count]
	cmp	cx, MAX_FAILS
	jae	.lf_done		; log is full; count-only

	; DI = fail_log + cx*6
	mov	ax, cx
	mov	bx, 6
	mul	bx
	mov	di, ax
	add	di, fail_log

	mov	al, [tmp_al]
	mov	[di], al		; [0] = fail code
	mov	ax, [cur_lba]
	mov	[di+1], ax		; [1..2] = LBA

	call	lba_to_chs		; CH/DH/CL
	mov	[di+3], ch
	mov	[di+4], dh
	mov	al, cl
	and	al, 0x3F
	mov	[di+5], al
.lf_done:
	pop	di
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

; progress_dot — print a dot every 16 sectors, newline every 64
progress_dot:
	push	ax
	push	dx
	mov	ax, [cur_lba]
	and	ax, 0x000F
	jnz	.pd_done
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	mov	ax, [cur_lba]
	and	ax, 0x003F
	jnz	.pd_done
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
.pd_done:
	pop	dx
	pop	ax
	ret

; pstr — print null-term string at DS:SI
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

; nl — print CR LF
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

; pdec — print AX as unsigned decimal
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

MAX_FAILS	equ	16

msg_usage	db	'Usage: DISKTEST [A|B]', 0x0D, 0x0A, 0
msg_banner	db	'DISKTEST - drive ', 0
msg_geom_err	db	'Cannot get drive geometry.', 0x0D, 0x0A, 0
msg_geom	db	'  ', 0
msg_x_heads	db	' cyl x ', 0
msg_x_spt	db	' head x ', 0
msg_equal_total	db	' sec = ', 0
msg_sectors	db	' sectors', 0
msg_warn	db	'WARNING: this destroys all data on the drive.', 0x0D, 0x0A
		db	'Continue? (Y/N) ', 0
msg_aborted	db	0x0D, 0x0A, 'Aborted.', 0x0D, 0x0A, 0
msg_nonce	db	'  nonce=$', 0
msg_phase1	db	0x0D, 0x0A, 'Phase 1 WRITE:  ', 0
msg_phase2	db	'Phase 2 READ:   ', 0
msg_summary	db	'=== Summary ===', 0x0D, 0x0A, 0
msg_sum_tested	db	'sectors tested: ', 0
msg_sum_werr	db	'write errors:   ', 0
msg_sum_rerr	db	'read errors:    ', 0
msg_sum_derr	db	'data mismatch:  ', 0
msg_failures	db	'Failures (code LBA=N CHS=cyl/head/sec):', 0x0D, 0x0A
		db	'  W=write err  R=read err  S=silent read  D=data mismatch', 0x0D, 0x0A, 0
msg_lbl_lba	db	'LBA=', 0
msg_lbl_chs	db	' CHS=', 0
msg_more	db	'... (', 0
msg_more_end	db	' more not shown)', 0x0D, 0x0A, 0
msg_pass	db	'*** ALL TESTS PASSED ***', 0
msg_fail	db	'*** TEST FAILED ***', 0

drive		db	1
cyls		db	0
heads		db	0
spt		db	0
total_sectors	dw	0
cur_lba		dw	0
nonce		dw	0
fail_count	dw	0
write_errs	dw	0
read_errs	dw	0
data_errs	dw	0
tmp_dh		db	0
tmp_al		db	0

	align 16
sector_buf	times 512 db 0

fail_log	times	MAX_FAILS*6 db 0
