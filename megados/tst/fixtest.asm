; FIXTEST.COM — regression tests for recent COMMAND.COM fixes.
;
;   Test 1: AH=3Eh close writes file size (+12/+14), not the pointer,
;           so mid-file overwrite must NOT shrink the recorded size.
;   Test 2: sft_dir_entry identifies the right entry at close time,
;           so multiple empty files can be created in one directory and
;           a later write into one of them goes to THAT entry only.
;   Test 3: AH=3Ch on an existing file frees the old cluster chain
;           instead of leaking it.
;   Test 4: AH=40h refuses to write through a read-only handle, and
;           AH=3Fh refuses to read from a write-only handle. Both
;           must return CF=1, AX=5 (access denied).
;   Test 5: AH=46h DUP2 must flush the target's old writable SFT to
;           disk when it drops the last reference, and must return
;           CF=1 AX=6 when the source handle is already closed.
;   Test 6: AH=3Bh CHDIR must keep the textual path (cur_dir_path)
;           in sync with cur_dir_cluster so AH=47h Get-Current-Dir
;           reports the new location. Runs CHDIR \ then \TEST.
;
; All test files live on drive A in the current directory. Each test
; prints PASS or FAIL with a short tag; summary line at the end.
; Exit code = number of failures.

	cpu	8086
	org	0x0100

	cld
	push	cs
	pop	ds
	push	cs
	pop	es

	mov	si, msg_banner
	call	pstr
	call	nl

	call	test1
	call	test2
	call	test3
	call	test4
	call	test5
	call	test6

	call	nl
	mov	si, msg_summary
	call	pstr
	mov	ax, [pass_count]
	call	pdec
	mov	si, msg_slash
	call	pstr
	mov	al, 6
	xor	ah, ah
	call	pdec
	mov	si, msg_passed
	call	pstr
	call	nl

	mov	al, 6
	sub	al, [pass_count]
	mov	ah, 0x4C
	int	0x21

; ============================================================================
; Test 1 — partial-overwrite close must not shrink file size
; ============================================================================
test1:
	mov	si, msg_t1
	call	pstr

	; Clean any leftover
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	; ignore error

	; Create file
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t1
	int	0x21
	jc	.t1_fail_create
	mov	[t1_handle], ax

	; Fill buffer with pattern: buf[i] = i & 0xFF
	mov	di, io_buf
	xor	cx, cx
.t1_fill:
	mov	al, cl
	stosb
	inc	cx
	cmp	cx, 1000
	jb	.t1_fill

	; Write 1000 bytes
	mov	bx, [t1_handle]
	mov	cx, 1000
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t1_fail_close
	cmp	ax, 1000
	jne	.t1_fail_close

	; Close
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen for write (mode 1)
	mov	ax, 0x3D01
	mov	dx, fn_t1
	int	0x21
	jc	.t1_fail_open
	mov	[t1_handle], ax

	; Seek to offset 100 from start
	mov	bx, [t1_handle]
	mov	ax, 0x4200
	xor	cx, cx
	mov	dx, 100
	int	0x21
	jc	.t1_fail_close2

	; Write 50 bytes of 0xEE
	mov	di, io_buf
	mov	cx, 50
	mov	al, 0xEE
	rep	stosb

	mov	bx, [t1_handle]
	mov	cx, 50
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t1_fail_close2
	cmp	ax, 50
	jne	.t1_fail_close2

	; Close
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen read-only and check size via seek-to-end
	mov	ax, 0x3D00
	mov	dx, fn_t1
	int	0x21
	jc	.t1_fail_open2
	mov	[t1_handle], ax

	mov	bx, [t1_handle]
	mov	ax, 0x4202		; Seek from end, offset 0
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t1_fail_close3
	; DX:AX = file size. Must be 1000.
	or	dx, dx
	jnz	.t1_fail_size_close
	cmp	ax, 1000
	jne	.t1_fail_size_close

	; Seek back to 0 and read the whole thing
	mov	bx, [t1_handle]
	mov	ax, 0x4200
	xor	cx, cx
	xor	dx, dx
	int	0x21

	mov	bx, [t1_handle]
	mov	cx, 1000
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t1_fail_close3
	cmp	ax, 1000
	jne	.t1_fail_close3

	; Close file before verifying content
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21

	; Verify:
	;   bytes 0..99  = original pattern (i & 0xFF)
	;   bytes 100..149 = 0xEE
	;   bytes 150..999 = pattern
	mov	si, io_buf
	xor	cx, cx
.t1_verify:
	mov	al, [si]
	cmp	cx, 100
	jb	.t1_v_orig
	cmp	cx, 150
	jb	.t1_v_over
	; 150..999: pattern
	cmp	al, cl
	jne	.t1_content_mismatch
	jmp	.t1_v_next
.t1_v_orig:
	cmp	al, cl
	jne	.t1_content_mismatch
	jmp	.t1_v_next
.t1_v_over:
	cmp	al, 0xEE
	jne	.t1_content_mismatch
.t1_v_next:
	inc	si
	inc	cx
	cmp	cx, 1000
	jb	.t1_verify

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	; Cleanup
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret

.t1_fail_create:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_create
	call	pstr
	call	nl
	ret
.t1_fail_close:
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21
	jmp	.t1_fail_generic
.t1_fail_open:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_open
	call	pstr
	call	nl
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret
.t1_fail_close2:
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21
	jmp	.t1_fail_generic
.t1_fail_open2:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_open2
	call	pstr
	call	nl
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret
.t1_fail_close3:
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21
	jmp	.t1_fail_generic
.t1_fail_size_close:
	mov	bx, [t1_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_size
	call	pstr
	call	nl
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret
.t1_content_mismatch:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_content
	call	pstr
	call	nl
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret
.t1_fail_generic:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t1_io
	call	pstr
	call	nl
	mov	dx, fn_t1
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 2 — three empty files; writing one must not spill into another
; ============================================================================
test2:
	mov	si, msg_t2
	call	pstr

	; Clean slate
	mov	dx, fn_t2a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t2b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t2c
	mov	ah, 0x41
	int	0x21

	; Create T2A (empty, close immediately)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t2a
	int	0x21
	jc	.t2_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Create T2B (empty, close)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t2b
	int	0x21
	jc	.t2_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Create T2C (empty, close)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t2c
	int	0x21
	jc	.t2_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Reopen T2B for write, write "HELLO", close
	mov	ax, 0x3D01
	mov	dx, fn_t2b
	int	0x21
	jc	.t2_fail_io
	mov	[t2_handle], ax

	mov	bx, [t2_handle]
	mov	cx, 5
	mov	dx, t2_data
	mov	ah, 0x40
	int	0x21

	mov	bx, [t2_handle]
	mov	ah, 0x3E
	int	0x21

	; Check T2A is still empty
	mov	dx, fn_t2a
	call	filesize
	jc	.t2_fail_io
	or	dx, dx
	jnz	.t2_fail_other
	or	ax, ax
	jnz	.t2_fail_other

	; Check T2C is still empty
	mov	dx, fn_t2c
	call	filesize
	jc	.t2_fail_io
	or	dx, dx
	jnz	.t2_fail_other
	or	ax, ax
	jnz	.t2_fail_other

	; Check T2B is 5 bytes, contents = "HELLO"
	mov	dx, fn_t2b
	call	filesize
	jc	.t2_fail_io
	or	dx, dx
	jnz	.t2_fail_target
	cmp	ax, 5
	jne	.t2_fail_target

	mov	ax, 0x3D00
	mov	dx, fn_t2b
	int	0x21
	jc	.t2_fail_io
	mov	[t2_handle], ax

	mov	bx, [t2_handle]
	mov	cx, 5
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21

	mov	bx, [t2_handle]
	mov	ah, 0x3E
	int	0x21

	mov	si, io_buf
	mov	di, t2_data
	mov	cx, 5
	repe	cmpsb
	jne	.t2_fail_target

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	call	test2_cleanup
	ret

.t2_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t2_io
	call	pstr
	call	nl
	call	test2_cleanup
	ret
.t2_fail_other:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t2_other
	call	pstr
	call	nl
	call	test2_cleanup
	ret
.t2_fail_target:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t2_target
	call	pstr
	call	nl
	call	test2_cleanup
	ret

test2_cleanup:
	mov	dx, fn_t2a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t2b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t2c
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 3 — truncate of an existing file must free the old cluster chain
; ============================================================================
test3:
	mov	si, msg_t3
	call	pstr

	; Clean any leftover
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21

	; Free clusters before any work
	mov	ah, 0x36
	mov	dl, 1			; A:
	int	0x21
	cmp	ax, 0xFFFF
	je	.t3_fail_disk
	mov	[t3_free_before], bx

	; Create T3 with 6144 bytes (6 clusters on 360K with 1024-byte clusters,
	; 3 clusters with 2048-byte clusters — either way >= 3 clusters)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t3
	int	0x21
	jc	.t3_fail_io
	mov	[t3_handle], ax

	; Fill io_buf with anything (use the pattern left over is fine)
	mov	di, io_buf
	mov	cx, 1024
	xor	ax, ax
	rep	stosw			; zero 2048 bytes

	; Write 3 x 2048 = 6144 bytes (in 2048-byte chunks)
	mov	cx, 3
.t3_write_loop:
	push	cx
	mov	bx, [t3_handle]
	mov	cx, 2048
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	pop	cx
	jc	.t3_fail_write
	cmp	ax, 2048
	jne	.t3_fail_write
	loop	.t3_write_loop

	; Close
	mov	bx, [t3_handle]
	mov	ah, 0x3E
	int	0x21

	; Get free after populated file exists (sanity)
	mov	ah, 0x36
	mov	dl, 1
	int	0x21
	mov	[t3_free_populated], bx

	; Now truncate by re-creating
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t3
	int	0x21
	jc	.t3_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Free clusters after truncate should == free_before
	mov	ah, 0x36
	mov	dl, 1
	int	0x21
	mov	cx, bx			; cx = free_after

	; Check that populated file actually reduced free count by >= 3
	mov	ax, [t3_free_before]
	sub	ax, [t3_free_populated]
	cmp	ax, 3
	jb	.t3_fail_noalloc

	; Check the truncated empty file reclaimed the clusters:
	;   free_after >= free_before (should be exactly equal since the
	;   truncated file has no cluster allocated either)
	mov	ax, cx			; free_after
	cmp	ax, [t3_free_before]
	jb	.t3_fail_leak

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21
	ret

.t3_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t3_io
	call	pstr
	call	nl
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21
	ret
.t3_fail_write:
	mov	bx, [t3_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t3_write
	call	pstr
	call	nl
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21
	ret
.t3_fail_disk:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t3_disk
	call	pstr
	call	nl
	ret
.t3_fail_noalloc:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t3_noalloc
	call	pstr
	call	nl
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21
	ret
.t3_fail_leak:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t3_leak
	call	pstr
	call	nl
	mov	dx, fn_t3
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 4 — handle permission: writes through RO handle must fail, and
; reads through WO handle must fail, both with AX=5 (access denied).
; ============================================================================
test4:
	mov	si, msg_t4
	call	pstr

	; Make sure the file exists and has a couple of bytes (so a read attempt
	; through the write-only handle would otherwise succeed).
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21

	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t4
	int	0x21
	jc	.t4_fail_io
	mov	[t4_handle], ax
	mov	bx, [t4_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21

	; --- Part A: open read-only, attempt to write ---
	mov	ax, 0x3D00
	mov	dx, fn_t4
	int	0x21
	jc	.t4_fail_io
	mov	[t4_handle], ax

	mov	bx, [t4_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	jnc	.t4_fail_ro_write	; should have rejected
	cmp	ax, 5
	jne	.t4_fail_ro_ax

	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21

	; --- Part B: open write-only, attempt to read ---
	mov	ax, 0x3D01
	mov	dx, fn_t4
	int	0x21
	jc	.t4_fail_io
	mov	[t4_handle], ax

	mov	bx, [t4_handle]
	mov	cx, 4
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jnc	.t4_fail_wo_read	; should have rejected
	cmp	ax, 5
	jne	.t4_fail_wo_ax

	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret

.t4_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t4_io
	call	pstr
	call	nl
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret
.t4_fail_ro_write:
	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t4_ro_write
	call	pstr
	call	nl
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret
.t4_fail_ro_ax:
	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t4_ro_ax
	call	pstr
	call	nl
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret
.t4_fail_wo_read:
	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t4_wo_read
	call	pstr
	call	nl
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret
.t4_fail_wo_ax:
	mov	bx, [t4_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t4_wo_ax
	call	pstr
	call	nl
	mov	dx, fn_t4
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 5 — DUP2 must finalize the target's old writable SFT AND must
; reject an already-closed source handle with AX=6.
; ============================================================================
test5:
	mov	si, msg_t5
	call	pstr

	; Clean slate
	mov	dx, fn_t5a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t5b
	mov	ah, 0x41
	int	0x21

	; --- Part A: DUP2 must flush writable target before replacing it ---

	; Create source B (empty, read-only later)
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t5b
	int	0x21
	jc	.t5_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; Create target A for write, pattern 0xA5 for 100 bytes
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t5a
	int	0x21
	jc	.t5_fail_io
	mov	[t5_a_handle], ax

	; Force DS=ES=CS — INT 21h may have clobbered one or both.
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	di, io_buf
	mov	cx, 100
	mov	al, 0xA5
	rep	stosb

	mov	bx, [t5_a_handle]
	mov	cx, 100
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t5_fail_io
	cmp	ax, 100
	jne	.t5_fail_io

	; Open B for read to get a separate SFT
	mov	ax, 0x3D00
	mov	dx, fn_t5b
	int	0x21
	jc	.t5_fail_io
	mov	[t5_b_handle], ax

	; DUP2 B onto A — drops A's SFT refcount to 0. That SFT still has
	; 100 bytes of dirty size/cluster state that MUST hit the directory.
	mov	bx, [t5_b_handle]
	mov	cx, [t5_a_handle]
	mov	ah, 0x46
	int	0x21
	jc	.t5_fail_io

	; Close both handles (they now both point at B's SFT; each close
	; just decrements refcount).
	mov	bx, [t5_a_handle]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t5_b_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen A.TMP — its directory entry MUST now say size=100 and the
	; content must be all 0xA5.
	mov	dx, fn_t5a
	call	filesize
	jc	.t5_fail_io
	or	dx, dx
	jnz	.t5_fail_flush
	cmp	ax, 100
	jne	.t5_fail_flush

	mov	ax, 0x3D00
	mov	dx, fn_t5a
	int	0x21
	jc	.t5_fail_io
	mov	[t5_a_handle], ax

	; INT 21 above may have clobbered DS/ES. Reassert before touching
	; io_buf, then zero it so stale 0xA5 from the earlier write can't
	; false-pass the verify if AH=3Fh returns short or fails.
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	di, io_buf
	mov	cx, 100
	xor	al, al
	rep	stosb

	mov	bx, [t5_a_handle]
	mov	cx, 100
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t5_fail_read
	cmp	ax, 100
	jne	.t5_fail_read
	push	cs
	pop	ds
	mov	bx, [t5_a_handle]
	mov	ah, 0x3E
	int	0x21

	; Verify bytes
	mov	si, io_buf
	mov	cx, 100
.t5_verify:
	mov	al, [si]
	cmp	al, 0xA5
	jne	.t5_fail_flush
	inc	si
	loop	.t5_verify

	; --- Part B: DUP2 on closed source must return CF=1, AX=6 ---
	; BX=5 is typically unused by any open file at this point.
	mov	bx, 5
	mov	ah, 0x3E
	int	0x21			; ensure it's closed (ignore errors)

	mov	bx, 5			; closed source
	mov	cx, 6			; any valid target index
	mov	ah, 0x46
	int	0x21
	jnc	.t5_fail_closed_src
	cmp	ax, 6
	jne	.t5_fail_closed_ax

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t5a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t5b
	mov	ah, 0x41
	int	0x21
	ret

.t5_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t5_io
	call	pstr
	call	nl
	jmp	.t5_cleanup
.t5_fail_flush:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t5_flush
	call	pstr
	call	nl
	jmp	.t5_cleanup
.t5_fail_closed_src:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t5_closed_src
	call	pstr
	call	nl
	jmp	.t5_cleanup
.t5_fail_closed_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t5_closed_ax
	call	pstr
	call	nl
	jmp	.t5_cleanup
.t5_fail_read:
	push	cs
	pop	ds
	mov	bx, [t5_a_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t5_read
	call	pstr
	call	nl
.t5_cleanup:
	mov	dx, fn_t5a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t5b
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 6 — AH=3Bh CHDIR must keep cur_dir_path in sync with the new
; cluster so AH=47h Get-Current-Dir reports the right location.
; Runs root → \TEST round-trip; restores \TEST at the end regardless
; of pass/fail so subsequent shell commands keep working.
; ============================================================================
test6:
	mov	si, msg_t6
	call	pstr

	; CHDIR \ (root)
	push	cs
	pop	ds
	mov	ah, 0x3B
	mov	dx, t6_root
	int	0x21
	jc	.t6_fail_chdir_root

	; AH=47h Get-Current-Dir (drive 0 = default, DS:SI = buffer)
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	ah, 0x47
	mov	dl, 0
	mov	si, t6_dirbuf
	int	0x21
	jc	.t6_fail_getcwd
	; Expect empty string at root
	push	cs
	pop	ds
	cmp	byte [t6_dirbuf], 0
	jne	.t6_fail_root_not_empty

	; CHDIR \TEST
	push	cs
	pop	ds
	mov	ah, 0x3B
	mov	dx, t6_test
	int	0x21
	jc	.t6_fail_chdir_test

	; AH=47h again — expect "TEST"
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	ah, 0x47
	mov	dl, 0
	mov	si, t6_dirbuf
	int	0x21
	jc	.t6_fail_getcwd
	push	cs
	pop	ds
	mov	si, t6_dirbuf
	mov	di, t6_test_expected
.t6_cmp:
	mov	al, [si]
	cmp	al, [di]
	jne	.t6_fail_wrong_dir
	or	al, al
	jz	.t6_ok
	inc	si
	inc	di
	jmp	.t6_cmp

.t6_ok:
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	ret

.t6_fail_chdir_root:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t6_chdir_root
	call	pstr
	call	nl
	jmp	.t6_restore
.t6_fail_chdir_test:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t6_chdir_test
	call	pstr
	call	nl
	jmp	.t6_restore
.t6_fail_getcwd:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t6_getcwd
	call	pstr
	call	nl
	jmp	.t6_restore
.t6_fail_root_not_empty:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t6_not_root
	call	pstr
	call	nl
	jmp	.t6_restore
.t6_fail_wrong_dir:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t6_wrong_dir
	call	pstr
	call	nl
.t6_restore:
	; Best-effort put the shell back in \TEST so the user's prompt
	; makes sense after a failure.
	push	cs
	pop	ds
	mov	ah, 0x3B
	mov	dx, t6_test
	int	0x21
	ret

; ============================================================================
; filesize — open file, seek to end, return size in DX:AX, close
; Input:  DX = filename ptr
; Output: DX:AX = file size, CF=0 success
; ============================================================================
filesize:
	push	bx
	mov	ax, 0x3D00
	int	0x21
	jc	.fs_err
	mov	bx, ax
	push	bx
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	pop	bx
	push	ax
	push	dx
	mov	ah, 0x3E
	int	0x21
	pop	dx
	pop	ax
	clc
	pop	bx
	ret
.fs_err:
	pop	bx
	stc
	ret

; ============================================================================
; Print helpers
; ============================================================================
pstr:
	push	ax
	push	dx
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

msg_banner	db	'FIXTEST - COMMAND.COM regression tests', 0
msg_summary	db	'Result: ', 0
msg_slash	db	'/', 0
msg_passed	db	' passed', 0
msg_pass	db	'PASS', 0
msg_fail	db	'FAIL ', 0

msg_t1		db	'T1 close/partial-write size: ', 0
msg_t1_create	db	'create', 0
msg_t1_open	db	'reopen for write', 0
msg_t1_open2	db	'reopen for read', 0
msg_t1_io	db	'io', 0
msg_t1_size	db	'size shrank', 0
msg_t1_content	db	'content corrupted', 0

msg_t2		db	'T2 empty-file close identity: ', 0
msg_t2_io	db	'io', 0
msg_t2_other	db	'wrong file got data', 0
msg_t2_target	db	'target mismatch', 0

msg_t3		db	'T3 truncate frees cluster chain: ', 0
msg_t3_io	db	'io', 0
msg_t3_write	db	'write', 0
msg_t3_disk	db	'get-free-space', 0
msg_t3_noalloc	db	'populated file reports no allocation', 0
msg_t3_leak	db	'clusters leaked on truncate', 0

msg_t4		db	'T4 handle permission enforced: ', 0
msg_t4_io	db	'io', 0
msg_t4_ro_write	db	'write through RO handle succeeded', 0
msg_t4_ro_ax	db	'wrong AX for RO-write reject', 0
msg_t4_wo_read	db	'read through WO handle succeeded', 0
msg_t4_wo_ax	db	'wrong AX for WO-read reject', 0

msg_t5		db	'T5 DUP2 close semantics: ', 0
msg_t5_io	db	'io', 0
msg_t5_flush	db	'DUP2 dropped writable SFT without flush', 0
msg_t5_closed_src db	'DUP2 with closed source returned success', 0
msg_t5_closed_ax db	'wrong AX for closed-source reject', 0
msg_t5_read	db	'AH=3Fh returned short/error', 0

msg_t6		db	'T6 AH=3Bh CHDIR updates textual path: ', 0
msg_t6_chdir_root db	'CHDIR \ failed', 0
msg_t6_chdir_test db	'CHDIR \TEST failed', 0
msg_t6_getcwd	db	'AH=47h failed', 0
msg_t6_not_root	db	'after CHDIR \ cur_dir_path not empty', 0
msg_t6_wrong_dir db	'after CHDIR \TEST cur_dir_path != TEST', 0

fn_t1		db	'T1.TMP', 0
fn_t2a		db	'T2A.TMP', 0
fn_t2b		db	'T2B.TMP', 0
fn_t2c		db	'T2C.TMP', 0
fn_t3		db	'T3.TMP', 0
fn_t4		db	'T4.TMP', 0
fn_t5a		db	'T5A.TMP', 0
fn_t5b		db	'T5B.TMP', 0

t6_root		db	'\', 0
t6_test		db	'\TEST', 0
t6_test_expected db	'TEST', 0
t6_dirbuf	times 64 db 0

t2_data		db	'HELLO'
t4_seed		db	'SEED'

pass_count	dw	0
t1_handle	dw	0
t2_handle	dw	0
t3_handle	dw	0
t4_handle	dw	0
t5_a_handle	dw	0
t5_b_handle	dw	0
t3_free_before	dw	0
t3_free_populated dw	0

io_buf:		times 2048 db 0
