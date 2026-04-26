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
;   Test 7: AH=4Eh FindFirst must resolve the directory portion of
;           a path-qualified filespec, and AH=4Fh FindNext must
;           continue from the saved search dir even after the caller
;           CHDIRs. Creates 3 files in \TEST, CHDIRs to root mid-walk,
;           and asserts all 3 still come back.
;   Test 8: AH=3Dh must mask sharing/inherit bits off the stored
;           access mode (so 0x80|read stays read-only and the AH=40h
;           write-guard still fires) and reject access codes 3-7 and
;           reserved bit 3 with AX=000Ch.
;   Test 9: AH=3Ch/3Dh/41h must reject directories, volume labels, and
;           (for creat/delete) read-only files with AX=5. AH=3Dh must
;           still permit opening a read-only file for read (mode 0).
;   Test 10: AH=42h seek-to-EOF on a file whose size is a whole cluster
;            must leave the handle in "need new cluster" state so a
;            subsequent AH=40h append lands in a fresh cluster instead
;            of overwriting byte 0 of the last existing cluster.
;   Test 11: AH=40h CX=0 (truncate at current pointer) must free the
;            FAT clusters past the new EOF and, when truncating to
;            zero, drop the start cluster too — pre-fix the size
;            shrank but the chain stayed allocated (leak).
;   Test 12: AH=56h rename must reject a destination that already
;            exists with AX=5 (otherwise it produces two dir entries
;            with the same 8.3 name); a same-name rename is a no-op
;            success.
;   Test 13: AH=3C/3D must not reuse a handle whose JFT entry is a
;            live AH=45h DUP alias — the SFT slot for that handle is
;            empty but JFT[bx] points at someone else's SFT, so a
;            naive scan would overwrite the alias and strand refcount
;            on the original SFT.
;   Test 14: AH=3C/39 must reject empty or path-only inputs that
;            resolve_path leaves with an all-spaces exec_fname,
;            otherwise they'd create blank 8.3 directory entries.
;   Test 15: term_common (AH=4Ch / INT 20h) must close ALL of the
;            child's JFT entries, not just 5+. EXECs T15CHLD which
;            DUP2's a file SFT onto handle 1 and exits without
;            closing — pre-fix the file size in the dir entry
;            stayed 0 because sft_finalize never ran.
;   Test 16: DIV/IDIV must fire INT 0 on quotient overflow (not
;            just on divide-by-zero). Installs a custom INT 0
;            handler and exercises both unsigned and signed
;            overflow plus the signed-IDIV $80 boundary case.
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
	call	test7
	call	test8
	call	test9
	call	test10
	call	test11
	call	test12
	call	test13
	call	test14
	call	test15
	call	test16

	call	nl
	mov	si, msg_summary
	call	pstr
	mov	ax, [pass_count]
	call	pdec
	mov	si, msg_slash
	call	pstr
	mov	al, 16
	xor	ah, ah
	call	pdec
	mov	si, msg_passed
	call	pstr
	call	nl

	mov	al, 16
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
; Test 7 — AH=4Eh / AH=4Fh: directory-qualified search must work, AND
; the search must continue against the original directory even after a
; CHDIR between FindFirst and FindNext.
; ============================================================================
test7:
	mov	si, msg_t7
	call	pstr

	; Make sure we start clean
	push	cs
	pop	ds
	mov	dx, fn_t7a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t7b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t7c
	mov	ah, 0x41
	int	0x21

	; Create three throwaway files (size doesn't matter — we just need
	; matching directory entries).
	push	cs
	pop	ds
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t7a
	int	0x21
	jc	.t7_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t7b
	int	0x21
	jc	.t7_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t7c
	int	0x21
	jc	.t7_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; AH=4Eh FindFirst on a path-qualified filespec while we sit in
	; \TEST. Pattern matches our 3 files plus possibly anything else
	; that already starts with T7 — that shouldn't exist on a fresh
	; disk run, but we also count strictly so a stray match would FAIL.
	push	cs
	pop	ds
	push	cs
	pop	es
	; Set DTA to a buffer we own
	mov	ah, 0x1A
	mov	dx, t7_dta
	int	0x21

	mov	ah, 0x4E
	xor	cx, cx			; attribute = 0 (regular files only)
	mov	dx, t7_pattern
	int	0x21
	jc	.t7_fail_findfirst
	mov	word [t7_count], 1

	; CHDIR to root MID-WALK to prove FindNext doesn't lean on
	; cur_dir_*. Old code re-read the current directory and would have
	; found nothing (root has no T7?.TMP).
	push	cs
	pop	ds
	mov	ah, 0x3B
	mov	dx, t6_root
	int	0x21
	jc	.t7_fail_chdir

.t7_loop:
	push	cs
	pop	ds
	mov	ah, 0x4F
	int	0x21
	jc	.t7_loop_done
	inc	word [t7_count]
	jmp	.t7_loop
.t7_loop_done:
	; AX=18 (no more files) is the only acceptable terminator.
	cmp	ax, 18
	jne	.t7_fail_findnext

	cmp	word [t7_count], 3
	jne	.t7_fail_count

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	jmp	.t7_cleanup

.t7_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t7_io
	call	pstr
	call	nl
	jmp	.t7_cleanup
.t7_fail_findfirst:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t7_findfirst
	call	pstr
	call	nl
	jmp	.t7_cleanup
.t7_fail_chdir:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t7_chdir
	call	pstr
	call	nl
	jmp	.t7_cleanup
.t7_fail_findnext:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t7_findnext
	call	pstr
	call	nl
	jmp	.t7_cleanup
.t7_fail_count:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t7_count
	call	pstr
	call	nl
.t7_cleanup:
	; Restore current directory to \TEST and remove the test files.
	push	cs
	pop	ds
	mov	ah, 0x3B
	mov	dx, t6_test
	int	0x21
	mov	dx, fn_t7a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t7b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t7c
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 8 — AH=3Dh must mask open-mode sharing/inherit bits and reject
; invalid access codes. Pre-fix, 0x80|read would be stored as 0x81 and
; bypass the AH=40h read-only guard (cmp byte, 1).
; ============================================================================
test8:
	mov	si, msg_t8
	call	pstr

	push	cs
	pop	ds

	; Seed the file with 4 bytes so AH=3F would otherwise have data.
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t8
	int	0x21
	jc	.t8_fail_io
	mov	[t8_handle], ax
	mov	bx, [t8_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21

	; --- Part A: AL=0x80 (inherit + read). Write through this handle
	; must be refused — pre-fix the stored mode was 0x81 and the AH=40h
	; guard missed it.
	mov	ax, 0x3D80
	mov	dx, fn_t8
	int	0x21
	jc	.t8_fail_a_open
	mov	[t8_handle], ax
	mov	bx, [t8_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	jnc	.t8_fail_a_write	; write should have been rejected
	cmp	ax, 5
	jne	.t8_fail_a_ax
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21

	; --- Part B: AL=0x82 (inherit + r/w). Write must succeed — mask
	; must not break a legitimately r/w-opened handle.
	mov	ax, 0x3D82
	mov	dx, fn_t8
	int	0x21
	jc	.t8_fail_b_open
	mov	[t8_handle], ax
	mov	bx, [t8_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	jc	.t8_fail_b_write
	cmp	ax, 4
	jne	.t8_fail_b_short
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21

	; --- Part C: AL=0x08 (reserved bit 3 set). Must fail AX=000Ch.
	mov	ax, 0x3D08
	mov	dx, fn_t8
	int	0x21
	jnc	.t8_fail_c_ok
	cmp	ax, 0x000C
	jne	.t8_fail_c_ax

	; --- Part D: AL=0x03 (invalid access code). Must fail AX=000Ch.
	mov	ax, 0x3D03
	mov	dx, fn_t8
	int	0x21
	jnc	.t8_fail_d_ok
	cmp	ax, 0x000C
	jne	.t8_fail_d_ax

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret

.t8_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_io
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_a_open:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_a_open
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_a_write:
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_a_write
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_a_ax:
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_a_ax
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_b_open:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_b_open
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_b_write:
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_b_write
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_b_short:
	mov	bx, [t8_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_b_short
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_c_ok:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_c_ok
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_c_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_c_ax
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_d_ok:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_d_ok
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret
.t8_fail_d_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t8_d_ax
	call	pstr
	call	nl
	mov	dx, fn_t8
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 9 — AH=3Ch / AH=3Dh / AH=41h must refuse directories, volume
; labels, and (for creat/delete) read-only files with AX=5. AH=3Dh
; read-mode against a RO file must still succeed.
; ============================================================================
test9:
	mov	si, msg_t9
	call	pstr

	push	cs
	pop	ds

	; Belt-and-braces: if a prior failed run left T9.TMP marked RO or
	; T9DIR lying around, clear the attribute and remove them so the
	; fresh setup below works. All no-ops if absent.
	mov	ax, 0x4301
	xor	cx, cx
	mov	dx, fn_t9
	int	0x21
	mov	dx, fn_t9
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t9dir
	mov	ah, 0x3A
	int	0x21

	; Create a throwaway directory to exercise the dir-reject paths —
	; using a dedicated name so a test regression can't corrupt \TEST
	; or its cluster chain.
	mov	ah, 0x39
	mov	dx, fn_t9dir
	int	0x21
	jc	.t9_fail_io

	; --- Part A: AH=3Dh r/w against T9DIR must fail AX=5.
	mov	ax, 0x3D02
	mov	dx, fn_t9dir
	int	0x21
	jnc	.t9_fail_a_ok
	cmp	ax, 5
	jne	.t9_fail_a_ax

	; --- Part B: AH=41h against T9DIR must fail AX=5 (and T9DIR must
	; still be there afterwards — verified by RMDIR below on cleanup).
	mov	dx, fn_t9dir
	mov	ah, 0x41
	int	0x21
	jnc	.t9_fail_b_ok
	cmp	ax, 5
	jne	.t9_fail_b_ax
	; Confirm the directory survived by CHDIR'ing into it.
	mov	ah, 0x3B
	mov	dx, fn_t9dir
	int	0x21
	jc	.t9_fail_b_gone
	; Back to root for the rest of the test.
	mov	ah, 0x3B
	mov	dx, fn_root
	int	0x21

	; --- Setup: create T9.TMP, write a few bytes, close, mark RO.
	push	cs
	pop	ds
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t9
	int	0x21
	jc	.t9_fail_io
	mov	[t9_handle], ax
	mov	bx, [t9_handle]
	mov	cx, 4
	mov	dx, t4_seed
	mov	ah, 0x40
	int	0x21
	mov	bx, [t9_handle]
	mov	ah, 0x3E
	int	0x21
	mov	ax, 0x4301		; Set attributes
	mov	cx, 1			; RO
	mov	dx, fn_t9
	int	0x21
	jc	.t9_fail_chmod

	; --- Part C: AH=41h on a RO file must fail AX=5.
	mov	dx, fn_t9
	mov	ah, 0x41
	int	0x21
	jnc	.t9_fail_c_ok
	cmp	ax, 5
	jne	.t9_fail_c_ax

	; --- Part D: AH=3Ch on an existing RO file must fail AX=5 (would
	; otherwise truncate it).
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t9
	int	0x21
	jnc	.t9_fail_d_ok
	cmp	ax, 5
	jne	.t9_fail_d_ax

	; --- Part E: AH=3Dh mode=1 (write) on a RO file must fail AX=5.
	mov	ax, 0x3D01
	mov	dx, fn_t9
	int	0x21
	jnc	.t9_fail_e_ok
	cmp	ax, 5
	jne	.t9_fail_e_ax

	; --- Part F: AH=3Dh mode=0 (read) on a RO file must succeed.
	mov	ax, 0x3D00
	mov	dx, fn_t9
	int	0x21
	jc	.t9_fail_f_ro_read
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; PASS — cleanup: clear RO and delete.
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	jmp	.t9_cleanup

.t9_fail_a_ok:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_a_ok
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_a_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_a_ax
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_b_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_b_ok
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_b_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_b_ax
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_b_gone:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_b_gone
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_io
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_chmod:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_chmod
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_c_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_c_ok
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_c_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_c_ax
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_d_ok:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_d_ok
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_d_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_d_ax
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_e_ok:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_e_ok
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_e_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_e_ax
	call	pstr
	call	nl
	jmp	.t9_cleanup
.t9_fail_f_ro_read:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t9_f_ro_read
	call	pstr
	call	nl
.t9_cleanup:
	; Clear RO (in case it was set) and remove T9.TMP / T9DIR. All
	; no-ops if absent.
	push	cs
	pop	ds
	mov	ax, 0x4301
	xor	cx, cx
	mov	dx, fn_t9
	int	0x21
	mov	dx, fn_t9
	mov	ah, 0x41
	int	0x21
	mov	ah, 0x3A
	mov	dx, fn_t9dir
	int	0x21
	ret

; ============================================================================
; Test 10 — AH=42h seek-to-EOF + AH=40h must append at a cluster
; boundary, not overwrite byte 0 of the last existing cluster.
; ============================================================================
test10:
	mov	si, msg_t10
	call	pstr

	push	cs
	pop	ds

	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21

	; Create file, fill it with 1024 'A' bytes (exactly one cluster).
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t10
	int	0x21
	jc	.t10_fail_io
	mov	[t10_handle], ax

	mov	di, io_buf
	mov	cx, 1024
	mov	al, 'A'
	rep	stosb

	mov	bx, [t10_handle]
	mov	cx, 1024
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t10_fail_io
	cmp	ax, 1024
	jne	.t10_fail_io

	mov	bx, [t10_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen r/w, seek to EOF (method 2, 0 offset). Expect DX:AX = 1024.
	mov	ax, 0x3D02
	mov	dx, fn_t10
	int	0x21
	jc	.t10_fail_io
	mov	[t10_handle], ax

	mov	bx, [t10_handle]
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t10_fail_io
	or	dx, dx
	jnz	.t10_fail_seek
	cmp	ax, 1024
	jne	.t10_fail_seek

	; Append 4 'B' bytes at the cluster boundary.
	mov	di, io_buf
	mov	cx, 4
	mov	al, 'B'
	rep	stosb

	mov	bx, [t10_handle]
	mov	cx, 4
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t10_fail_io
	cmp	ax, 4
	jne	.t10_fail_io

	mov	bx, [t10_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen read-only; verify size is 1028 and contents are exactly
	; 1024×'A' then 4×'B'. Pre-fix the first 4 bytes would be 'B' and
	; size would be 1024 (because bytes 0..3 of the original cluster
	; got trampled).
	mov	ax, 0x3D00
	mov	dx, fn_t10
	int	0x21
	jc	.t10_fail_io
	mov	[t10_handle], ax

	mov	bx, [t10_handle]
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t10_fail_io
	or	dx, dx
	jnz	.t10_fail_size
	cmp	ax, 1028
	jne	.t10_fail_size

	mov	bx, [t10_handle]
	mov	ax, 0x4200
	xor	cx, cx
	xor	dx, dx
	int	0x21

	mov	bx, [t10_handle]
	mov	cx, 1028
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t10_fail_io
	cmp	ax, 1028
	jne	.t10_fail_size

	mov	bx, [t10_handle]
	mov	ah, 0x3E
	int	0x21

	; Byte 0 must still be 'A'; byte 1024 must be 'B'.
	mov	si, io_buf
	xor	cx, cx
.t10_verify:
	mov	al, [si]
	cmp	cx, 1024
	jb	.t10_v_orig
	cmp	al, 'B'
	jne	.t10_content
	jmp	.t10_v_next
.t10_v_orig:
	cmp	al, 'A'
	jne	.t10_content
.t10_v_next:
	inc	si
	inc	cx
	cmp	cx, 1028
	jb	.t10_verify

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21
	ret

.t10_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t10_io
	call	pstr
	call	nl
	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21
	ret
.t10_fail_seek:
	mov	bx, [t10_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t10_seek
	call	pstr
	call	nl
	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21
	ret
.t10_fail_size:
	mov	bx, [t10_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t10_size
	call	pstr
	call	nl
	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21
	ret
.t10_content:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t10_content
	call	pstr
	call	nl
	mov	dx, fn_t10
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 11 — AH=40h CX=0 truncate must free abandoned FAT clusters and,
; for truncate-to-zero, also drop the start cluster.
;
; Part A: write 3072 bytes (3 clusters), truncate to 0 via AH=40 CX=0,
;         confirm size = 0 AND free-cluster count returns to baseline
;         (no leak).
; Part B: write 3072 bytes again, seek to 1000, AH=40 CX=0, confirm
;         size = 1000 AND free count == baseline - 1 (one cluster kept).
; Part C: write 3072 bytes again, seek to 1024 (cluster boundary),
;         AH=40 CX=0, then immediately append 4 bytes through the same
;         handle. Pre-fix the SFT's current_cluster still pointed at
;         the (now freed) second cluster from the seek, and the write
;         would land in that freed cluster — silent FAT corruption.
;         Post-fix the write must land in a freshly allocated cluster
;         and the file size becomes 1028.
; ============================================================================
test11:
	mov	si, msg_t11
	call	pstr

	push	cs
	pop	ds
	push	cs
	pop	es			; rep stosb writes to ES:DI

	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21

	; Baseline free-cluster count before any allocation.
	mov	ah, 0x36
	mov	dl, 1			; A:
	int	0x21
	cmp	ax, 0xFFFF
	je	.t11_fail_disk
	mov	[t11_free_baseline], bx
	; AH=36 used to clobber ES (now fixed). Reset defensively so this
	; test still works against an older COMMAND.COM if anyone runs it.
	push	cs
	pop	es

	; --- Part A: truncate-to-zero ---
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	; Fill io_buf with 'X' so writes touch real cluster contents.
	mov	di, io_buf
	mov	cx, 1024
	mov	al, 'X'
	rep	stosb

	; Write 3 × 1024 = 3072 bytes.
	mov	cx, 3
.t11_a_write:
	push	cx
	mov	bx, [t11_handle]
	mov	cx, 1024
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	pop	cx
	jc	.t11_fail_a_write
	cmp	ax, 1024
	jne	.t11_fail_a_write
	loop	.t11_a_write

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen r/w, seek to 0, AH=40 CX=0 (truncate).
	mov	ax, 0x3D02
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	bx, [t11_handle]
	mov	ax, 0x4200
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t11_fail_io

	mov	bx, [t11_handle]
	xor	cx, cx			; CX=0 → truncate
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t11_fail_a_trunc

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Verify size = 0.
	mov	ax, 0x3D00
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax
	mov	bx, [t11_handle]
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t11_fail_io
	or	ax, ax
	jne	.t11_fail_a_size
	or	dx, dx
	jne	.t11_fail_a_size
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Free count must be back to baseline (full reclaim).
	mov	ah, 0x36
	mov	dl, 1
	int	0x21
	mov	ax, [t11_free_baseline]
	cmp	bx, ax
	jb	.t11_fail_a_leak
	push	cs
	pop	es			; defensive: AH=36 historically clobbered ES

	; --- Part B: partial truncate ---
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21

	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	di, io_buf
	mov	cx, 1024
	mov	al, 'Y'
	rep	stosb

	mov	cx, 3
.t11_b_write:
	push	cx
	mov	bx, [t11_handle]
	mov	cx, 1024
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	pop	cx
	jc	.t11_fail_b_write
	cmp	ax, 1024
	jne	.t11_fail_b_write
	loop	.t11_b_write

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen r/w, seek to 1000, AH=40 CX=0 (truncate to 1000).
	mov	ax, 0x3D02
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	bx, [t11_handle]
	mov	ax, 0x4200
	xor	cx, cx
	mov	dx, 1000
	int	0x21
	jc	.t11_fail_io

	mov	bx, [t11_handle]
	xor	cx, cx
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t11_fail_b_trunc

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Verify size = 1000.
	mov	ax, 0x3D00
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax
	mov	bx, [t11_handle]
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t11_fail_io
	or	dx, dx
	jne	.t11_fail_b_size
	cmp	ax, 1000
	jne	.t11_fail_b_size
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Free count must be baseline - 1 (just the first cluster kept).
	mov	ah, 0x36
	mov	dl, 1
	int	0x21
	mov	ax, [t11_free_baseline]
	sub	ax, bx			; AX = baseline - free_after = clusters used
	cmp	ax, 1
	jne	.t11_fail_b_leak
	push	cs
	pop	es			; defensive: AH=36 historically clobbered ES

	; --- Part C: post-truncate write at cluster boundary ---
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21

	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	di, io_buf
	mov	cx, 1024
	mov	al, 'Z'
	rep	stosb

	mov	cx, 3
.t11_c_write:
	push	cx
	mov	bx, [t11_handle]
	mov	cx, 1024
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	pop	cx
	jc	.t11_fail_c_write
	cmp	ax, 1024
	jne	.t11_fail_c_write
	loop	.t11_c_write

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen r/w, seek to 1024 (cluster boundary), truncate, then
	; APPEND 4 'Q' bytes through the same handle without closing.
	mov	ax, 0x3D02
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	bx, [t11_handle]
	mov	ax, 0x4200
	xor	cx, cx
	mov	dx, 1024
	int	0x21
	jc	.t11_fail_io

	mov	bx, [t11_handle]
	xor	cx, cx
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t11_fail_c_trunc

	; Append 4 'Q' bytes immediately, same handle.
	mov	di, io_buf
	mov	cx, 4
	mov	al, 'Q'
	rep	stosb

	mov	bx, [t11_handle]
	mov	cx, 4
	mov	dx, io_buf
	mov	ah, 0x40
	int	0x21
	jc	.t11_fail_c_append
	cmp	ax, 4
	jne	.t11_fail_c_append

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Reopen RO and verify size = 1028 and bytes 1024..1027 = 'Q'.
	mov	ax, 0x3D00
	mov	dx, fn_t11
	int	0x21
	jc	.t11_fail_io
	mov	[t11_handle], ax

	mov	bx, [t11_handle]
	mov	ax, 0x4202
	xor	cx, cx
	xor	dx, dx
	int	0x21
	jc	.t11_fail_io
	or	dx, dx
	jne	.t11_fail_c_size
	cmp	ax, 1028
	jne	.t11_fail_c_size

	mov	bx, [t11_handle]
	mov	ax, 0x4200
	xor	cx, cx
	xor	dx, dx
	int	0x21

	mov	bx, [t11_handle]
	mov	cx, 1028
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t11_fail_io
	cmp	ax, 1028
	jne	.t11_fail_c_size

	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21

	; Bytes 0..1023 must be 'Z', bytes 1024..1027 must be 'Q'.
	mov	si, io_buf
	xor	cx, cx
.t11_c_verify:
	mov	al, [si]
	cmp	cx, 1024
	jb	.t11_c_v_orig
	cmp	al, 'Q'
	jne	.t11_fail_c_content
	jmp	.t11_c_v_next
.t11_c_v_orig:
	cmp	al, 'Z'
	jne	.t11_fail_c_content
.t11_c_v_next:
	inc	si
	inc	cx
	cmp	cx, 1028
	jb	.t11_c_verify

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret

.t11_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_io
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_disk:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_disk
	call	pstr
	call	nl
	ret
.t11_fail_a_write:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_a_write
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_a_trunc:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_a_trunc
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_a_size:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_a_size
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_a_leak:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_a_leak
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_b_write:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_b_write
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_b_trunc:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_b_trunc
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_b_size:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_b_size
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_b_leak:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_b_leak
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_c_write:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_c_write
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_c_trunc:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_c_trunc
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_c_append:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_c_append
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_c_size:
	mov	bx, [t11_handle]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_c_size
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret
.t11_fail_c_content:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t11_c_content
	call	pstr
	call	nl
	mov	dx, fn_t11
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 12 — AH=56h rename must reject a duplicate destination, leave
; the source intact, and treat same-name rename as a no-op success.
; ============================================================================
test12:
	mov	si, msg_t12
	call	pstr

	push	cs
	pop	ds
	push	cs
	pop	es

	; Clean any leftover from a prior run.
	mov	dx, fn_t12a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12c
	mov	ah, 0x41
	int	0x21

	; --- Part A: rename to existing destination must fail ---
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12a
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12b
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	; AH=56h: DS:DX = old, ES:DI = new
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12a
	mov	di, fn_t12b
	mov	ah, 0x56
	int	0x21
	jnc	.t12_fail_a_ok
	cmp	ax, 5
	jne	.t12_fail_a_ax

	; --- Verify source survived: AH=41 delete T12A must succeed.
	push	cs
	pop	ds
	mov	dx, fn_t12a
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_a_src_gone

	; --- Verify exactly one T12B exists: first delete OK, second NOT.
	mov	dx, fn_t12b
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_a_dst_gone
	mov	dx, fn_t12b
	mov	ah, 0x41
	int	0x21
	jnc	.t12_fail_a_duplicate
	cmp	ax, 2
	jne	.t12_fail_a_duplicate

	; --- Part B: same-name rename is a no-op success ---
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12c
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12c
	mov	di, fn_t12c
	mov	ah, 0x56
	int	0x21
	jc	.t12_fail_b_same_failed

	; T12C must still be there afterwards (delete must succeed).
	push	cs
	pop	ds
	mov	dx, fn_t12c
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_b_lost

	; --- Part C: path-qualified destination must be rejected ---
	; Pre-fix parse_83_filename bailed on the first '\' and left the
	; new-name buffer all-spaces, so the rename overwrote the source
	; entry's name with blanks.
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12d
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12d
	mov	di, fn_t12bad_path
	mov	ah, 0x56
	int	0x21
	jnc	.t12_fail_c_ok
	cmp	ax, 3
	jne	.t12_fail_c_ax

	; Drive-qualified destination must also be rejected.
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12d
	mov	di, fn_t12bad_drive
	mov	ah, 0x56
	int	0x21
	jnc	.t12_fail_c_ok2
	cmp	ax, 3
	jne	.t12_fail_c_ax2

	; T12D must still be there (source untouched by rejected renames).
	push	cs
	pop	ds
	mov	dx, fn_t12d
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_c_src_gone

	; --- Part D: rename MISSING -> MISSING must report AX=2 (file not
	; found), not be silently short-circuited by the same-name path.
	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12_missing
	mov	di, fn_t12_missing
	mov	ah, 0x56
	int	0x21
	jnc	.t12_fail_d_ok
	cmp	ax, 2
	jne	.t12_fail_d_ax

	; --- Part E: rename MISSING -> EXISTING must also report AX=2,
	; not AX=5 (the destination-exists check should never fire when
	; the source isn't there).
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12e
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12_missing
	mov	di, fn_t12e
	mov	ah, 0x56
	int	0x21
	jnc	.t12_fail_e_ok
	cmp	ax, 2
	jne	.t12_fail_e_ax

	; T12E must still be there (rejected rename mustn't touch it).
	push	cs
	pop	ds
	mov	dx, fn_t12e
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_e_dst_gone

	; --- Part F: positive-path rename — A -> B where B doesn't exist
	; must succeed. Guards against the entire rename pipeline silently
	; regressing into a no-op or hard-fail.
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t12f
	int	0x21
	jc	.t12_fail_io
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21

	push	cs
	pop	ds
	push	cs
	pop	es
	mov	dx, fn_t12f
	mov	di, fn_t12g
	mov	ah, 0x56
	int	0x21
	jc	.t12_fail_f_failed

	; T12F must be gone, T12G must be present.
	push	cs
	pop	ds
	mov	dx, fn_t12f
	mov	ah, 0x41
	int	0x21
	jnc	.t12_fail_f_src_remains
	cmp	ax, 2
	jne	.t12_fail_f_src_remains
	mov	dx, fn_t12g
	mov	ah, 0x41
	int	0x21
	jc	.t12_fail_f_dst_missing

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	ret

.t12_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_io
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_a_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_a_ok
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_a_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_a_ax
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_a_src_gone:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_a_src_gone
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_a_dst_gone:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_a_dst_gone
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_a_duplicate:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_a_duplicate
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_b_same_failed:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_b_same_failed
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_b_lost:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_b_lost
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_c_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_c_ok
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_c_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_c_ax
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_c_ok2:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_c_ok2
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_c_ax2:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_c_ax2
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_c_src_gone:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_c_src_gone
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_d_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_d_ok
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_d_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_d_ax
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_e_ok:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_e_ok
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_e_ax:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_e_ax
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_e_dst_gone:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_e_dst_gone
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_f_failed:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_f_failed
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_f_src_remains:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_f_src_remains
	call	pstr
	call	nl
	jmp	.t12_cleanup
.t12_fail_f_dst_missing:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t12_f_dst_missing
	call	pstr
	call	nl
.t12_cleanup:
	push	cs
	pop	ds
	mov	dx, fn_t12a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12c
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12d
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12e
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12f
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t12g
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 13 — AH=45h DUP alias must not be silently overwritten by a
; later AH=3D/3C open. Open T13A, DUP it, then open T13B; the open
; must skip the dup-aliased handle (SFT empty but JFT in use) and
; return a different handle number. Verify the dup alias and the
; new handle still address their respective files.
; ============================================================================
test13:
	mov	si, msg_t13
	call	pstr

	push	cs
	pop	ds
	push	cs
	pop	es

	mov	dx, fn_t13a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t13b
	mov	ah, 0x41
	int	0x21

	; Create T13A with one byte 'A' so we can verify reads later.
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t13a
	int	0x21
	jc	.t13_fail_io
	mov	bx, ax
	push	bx
	mov	cx, 1
	mov	dx, t13_a_seed
	mov	ah, 0x40
	int	0x21
	pop	bx
	mov	ah, 0x3E
	int	0x21

	; Create T13B with one byte 'B'.
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t13b
	int	0x21
	jc	.t13_fail_io
	mov	bx, ax
	push	bx
	mov	cx, 1
	mov	dx, t13_b_seed
	mov	ah, 0x40
	int	0x21
	pop	bx
	mov	ah, 0x3E
	int	0x21

	; Open T13A for read.
	mov	ax, 0x3D00
	mov	dx, fn_t13a
	int	0x21
	jc	.t13_fail_io
	mov	[t13_h_a], ax

	; DUP it.
	mov	bx, [t13_h_a]
	mov	ah, 0x45
	int	0x21
	jc	.t13_fail_dup
	mov	[t13_h_dup], ax

	; Open T13B for read. Must NOT collide with the dup alias.
	mov	ax, 0x3D00
	mov	dx, fn_t13b
	int	0x21
	jc	.t13_fail_io
	mov	[t13_h_b], ax

	mov	ax, [t13_h_b]
	cmp	ax, [t13_h_dup]
	je	.t13_fail_collision

	; Read through the dup handle — it must still see T13A's 'A'.
	mov	bx, [t13_h_dup]
	mov	cx, 1
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t13_fail_dup_read
	cmp	ax, 1
	jne	.t13_fail_dup_read
	cmp	byte [io_buf], 'A'
	jne	.t13_fail_dup_content

	; Read through the new handle — it must see T13B's 'B'.
	mov	bx, [t13_h_b]
	mov	cx, 1
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t13_fail_b_read
	cmp	ax, 1
	jne	.t13_fail_b_read
	cmp	byte [io_buf], 'B'
	jne	.t13_fail_b_content

	; Close the AH=3D side. Keep the dup alias open for Part B.
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21

	; --- Part B: same guard via the AH=3Ch create path ---
	; Make sure the create target doesn't already exist, then create
	; via AH=3Ch and assert the returned handle != dup-aliased handle.
	push	cs
	pop	ds
	mov	dx, fn_t13c
	mov	ah, 0x41
	int	0x21

	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t13c
	int	0x21
	jc	.t13_fail_b_io
	mov	[t13_h_b], ax

	cmp	ax, [t13_h_dup]
	je	.t13_fail_b_collision

	; Dup alias must still point at T13A — re-read first byte.
	mov	bx, [t13_h_dup]
	xor	cx, cx
	xor	dx, dx
	mov	ax, 0x4200
	int	0x21
	mov	bx, [t13_h_dup]
	mov	cx, 1
	mov	dx, io_buf
	mov	ah, 0x3F
	int	0x21
	jc	.t13_fail_b_dup_read
	cmp	ax, 1
	jne	.t13_fail_b_dup_read
	cmp	byte [io_buf], 'A'
	jne	.t13_fail_b_dup_content

	; Close everything.
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	jmp	.t13_cleanup

.t13_fail_io:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_io
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_dup:
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_dup
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_collision:
	; Close everything still open.
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_collision
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_dup_read:
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_dup_read
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_dup_content:
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_dup_content
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_read:
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_read
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_content:
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_content
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_io:
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_io
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_collision:
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_collision
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_dup_read:
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_dup_read
	call	pstr
	call	nl
	jmp	.t13_cleanup
.t13_fail_b_dup_content:
	mov	bx, [t13_h_b]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_dup]
	mov	ah, 0x3E
	int	0x21
	mov	bx, [t13_h_a]
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t13_b_dup_content
	call	pstr
	call	nl
.t13_cleanup:
	push	cs
	pop	ds
	mov	dx, fn_t13a
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t13b
	mov	ah, 0x41
	int	0x21
	mov	dx, fn_t13c
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 14 — AH=3C / AH=39 must reject paths where resolve_path leaves
; exec_fname all-spaces (empty input or trailing-slash path), so they
; can't create blank-named directory entries.
; ============================================================================
test14:
	mov	si, msg_t14
	call	pstr

	push	cs
	pop	ds
	push	cs
	pop	es

	; --- AH=3C with empty filename
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t14_empty
	int	0x21
	jnc	.t14_fail_3c_empty
	; --- AH=3C with root path "\"
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t14_root
	int	0x21
	jnc	.t14_fail_3c_root
	; --- AH=39 with empty filename
	mov	ah, 0x39
	mov	dx, fn_t14_empty
	int	0x21
	jnc	.t14_fail_39_empty
	; --- AH=39 with root path "\"
	mov	ah, 0x39
	mov	dx, fn_t14_root
	int	0x21
	jnc	.t14_fail_39_root

	; Sanity: a real create with a sane name still works (proves we
	; didn't break the happy path).
	mov	ah, 0x3C
	xor	cx, cx
	mov	dx, fn_t14_real
	int	0x21
	jc	.t14_fail_real
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	dx, fn_t14_real
	mov	ah, 0x41
	int	0x21

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	ret

.t14_fail_3c_empty:
	; If a handle was actually returned, close + delete it.
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t14_3c_empty
	call	pstr
	call	nl
	ret
.t14_fail_3c_root:
	mov	bx, ax
	mov	ah, 0x3E
	int	0x21
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t14_3c_root
	call	pstr
	call	nl
	ret
.t14_fail_39_empty:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t14_39_empty
	call	pstr
	call	nl
	ret
.t14_fail_39_root:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t14_39_root
	call	pstr
	call	nl
	ret
.t14_fail_real:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t14_real
	call	pstr
	call	nl
	ret

; ============================================================================
; Test 15 — term_common must close child JFT entries 0..MAX, not
; just 5+. EXEC T15CHLD which DUP2's a file SFT onto stdout and
; exits without explicit close. Verify T15.TMP's dir-entry size
; reflects the 4 bytes the child wrote — pre-fix it stayed 0
; because sft_finalize never ran (refcount stranded at 1 by the
; uncleaned JFT[1] alias).
; ============================================================================
test15:
	mov	si, msg_t15
	call	pstr

	push	cs
	pop	ds
	push	cs
	pop	es

	; T15CHLD.COM lives in \TEST. Earlier tests can leave us at root
	; (T7/T9 CHDIR \ mid-walk and don't restore), and AH=4B only
	; searches the current directory.
	mov	ah, 0x3B
	mov	dx, t6_test		; '\TEST'
	int	0x21
	jc	.t15_fail_chdir
	push	cs
	pop	ds

	mov	dx, fn_t15_tmp
	mov	ah, 0x41
	int	0x21

	; .COM programs are launched with all available memory allocated
	; to their PSP. AH=4B needs free memory to give the child, so we
	; shrink ourselves first via AH=4A. 0x1000 paragraphs (64KB) is
	; plenty for FIXTEST and keeps SS:SP near FFFE intact.
	push	cs
	pop	es
	mov	bx, 0x1000
	mov	ah, 0x4A
	int	0x21
	push	cs
	pop	ds
	push	cs
	pop	es
	jc	.t15_fail_resize

	; Build EXEC parameter block.
	mov	word [t15_exec_pb], 0			; env = inherit
	mov	word [t15_exec_pb+2], t15_cmdtail	; cmd tail off
	mov	word [t15_exec_pb+4], cs		; cmd tail seg
	mov	word [t15_exec_pb+6], 0x005C		; FCB1 = PSP default
	mov	word [t15_exec_pb+8], cs
	mov	word [t15_exec_pb+10], 0x006C		; FCB2
	mov	word [t15_exec_pb+12], cs

	mov	ax, 0x4B00
	mov	dx, fn_t15_child
	mov	bx, t15_exec_pb
	push	cs
	pop	es
	int	0x21

	; Reset DS/ES BEFORE checking CF — AH=4B leaves DS = SHELL_SEG
	; on both success and failure, so any error message printed via
	; pstr would otherwise come out as garbage.
	push	cs
	pop	ds
	push	cs
	pop	es
	jc	.t15_fail_exec

	; Open T15.TMP read-only and seek to end to read the dir-entry
	; size. Pre-fix this is 0 (sft_finalize skipped); post-fix it's 4.
	mov	dx, fn_t15_tmp
	call	filesize
	jc	.t15_fail_size_call
	or	dx, dx
	jne	.t15_fail_size
	cmp	ax, 4
	jne	.t15_fail_size

	; Cleanup
	mov	dx, fn_t15_tmp
	mov	ah, 0x41
	int	0x21

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	ret

.t15_fail_chdir:
	push	cs
	pop	ds
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t15_chdir
	call	pstr
	call	nl
	ret
.t15_fail_resize:
	push	cs
	pop	ds
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t15_resize
	call	pstr
	call	nl
	ret
.t15_fail_exec:
	push	cs
	pop	ds
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t15_exec
	call	pstr
	call	nl
	mov	dx, fn_t15_tmp
	mov	ah, 0x41
	int	0x21
	ret
.t15_fail_size_call:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t15_size_call
	call	pstr
	call	nl
	mov	dx, fn_t15_tmp
	mov	ah, 0x41
	int	0x21
	ret
.t15_fail_size:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t15_size
	call	pstr
	call	nl
	mov	dx, fn_t15_tmp
	mov	ah, 0x41
	int	0x21
	ret

; ============================================================================
; Test 16 — DIV/IDIV must fire INT 0 on quotient overflow
;
; Real 8086 fires INT 0 on:
;   - divide by zero
;   - quotient too large to fit in destination (AL or AX)
;
; Hooks INT 0 to a flag-setter, runs five DIV/IDIV scenarios, asserts
; the flag fired (or didn't) for each case, restores INT 0 on the way
; out via the saved vector regardless of pass/fail.
; ============================================================================
test16:
	mov	si, msg_t16
	call	pstr

	push	cs
	pop	ds

	; Save current INT 0 vector via AH=35.
	mov	ax, 0x3500
	int	0x21
	push	cs
	pop	ds
	mov	[t16_orig_off], bx
	mov	[t16_orig_seg], es

	; Install our INT 0 handler.
	push	cs
	pop	ds
	mov	ax, 0x2500
	mov	dx, t16_int0_handler
	int	0x21

	push	cs
	pop	ds

	; --- Case 1: byte DIV with quotient overflow ($FFFF / 1 → $FFFF, doesn't fit AL)
	mov	byte [t16_div0_flag], 0
	mov	ax, 0xFFFF
	mov	bl, 1
	div	bl
	cmp	byte [t16_div0_flag], 1
	jne	.t16_fail_c1

	; --- Case 2: byte DIV no overflow ($00FF / 2 → 127, fits)
	mov	byte [t16_div0_flag], 0
	mov	ax, 0x00FF
	mov	bl, 2
	div	bl
	cmp	byte [t16_div0_flag], 0
	jne	.t16_fail_c2_fired
	cmp	al, 127
	jne	.t16_fail_c2_quot
	cmp	ah, 1
	jne	.t16_fail_c2_rem

	; --- Case 3: word DIV with overflow ($00010000 / 1 → $10000, doesn't fit AX)
	mov	byte [t16_div0_flag], 0
	mov	dx, 1
	mov	ax, 0
	mov	bx, 1
	div	bx
	cmp	byte [t16_div0_flag], 1
	jne	.t16_fail_c3

	; --- Case 4: byte IDIV with positive overflow (128 / 1 → +128, > +127 max)
	mov	byte [t16_div0_flag], 0
	mov	ax, 128
	mov	bl, 1
	idiv	bl
	cmp	byte [t16_div0_flag], 1
	jne	.t16_fail_c4

	; --- Case 5: byte IDIV at the exact $80 / -128 boundary (-128 / 1 → -128 = $80, fits)
	mov	byte [t16_div0_flag], 0
	mov	ax, 0xFF80		; -128 sign-extended in AX
	mov	bl, 1
	idiv	bl
	cmp	byte [t16_div0_flag], 0
	jne	.t16_fail_c5_fired
	cmp	al, 0x80		; -128 result
	jne	.t16_fail_c5_quot

	; PASS
	mov	si, msg_pass
	call	pstr
	call	nl
	inc	word [pass_count]
	jmp	.t16_cleanup

.t16_fail_c1:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c1
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c2_fired:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c2_fired
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c2_quot:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c2_quot
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c2_rem:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c2_rem
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c3:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c3
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c4:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c4
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c5_fired:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c5_fired
	call	pstr
	call	nl
	jmp	.t16_cleanup
.t16_fail_c5_quot:
	mov	si, msg_fail
	call	pstr
	mov	si, msg_t16_c5_quot
	call	pstr
	call	nl
.t16_cleanup:
	; Restore the original INT 0 vector (AH=25 with DS:DX = saved seg:off).
	push	cs
	pop	ds
	push	ds
	mov	dx, [t16_orig_off]
	mov	ax, [t16_orig_seg]
	mov	ds, ax
	mov	ax, 0x2500
	int	0x21
	pop	ds
	ret

; INT 0 handler: just sets a flag. CS-relative storage so the handler
; doesn't need to touch DS state on a possibly-fragile call site.
t16_int0_handler:
	push	ax
	push	ds
	push	cs
	pop	ds
	mov	byte [t16_div0_flag], 1
	pop	ds
	pop	ax
	iret

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

msg_t7		db	'T7 AH=4E/4F path search + post-CHDIR: ', 0
msg_t7_io	db	'io', 0
msg_t7_findfirst db	'FindFirst path-qualified failed', 0
msg_t7_chdir	db	'mid-walk CHDIR failed', 0
msg_t7_findnext	db	'FindNext returned wrong AX on exhaustion', 0
msg_t7_count	db	'wrong number of matches', 0

msg_t8		db	'T8 AH=3Dh masks open-mode bits: ', 0
msg_t8_io	db	'io', 0
msg_t8_a_open	db	'open inherit+read failed', 0
msg_t8_a_write	db	'write through 0x80|read succeeded', 0
msg_t8_a_ax	db	'wrong AX for masked-RO reject', 0
msg_t8_b_open	db	'open inherit+rw failed', 0
msg_t8_b_write	db	'write through 0x80|rw rejected', 0
msg_t8_b_short	db	'write through 0x80|rw short', 0
msg_t8_c_ok	db	'open with reserved bit 3 succeeded', 0
msg_t8_c_ax	db	'wrong AX for reserved-bit reject', 0
msg_t8_d_ok	db	'open with access code 3 succeeded', 0
msg_t8_d_ax	db	'wrong AX for invalid-access reject', 0

msg_t9		db	'T9 dir/VOL/RO rejected: ', 0
msg_t9_io	db	'setup io', 0
msg_t9_chmod	db	'chmod RO failed', 0
msg_t9_a_ok	db	'AH=3Dh rw on directory succeeded', 0
msg_t9_a_ax	db	'wrong AX for AH=3Dh dir reject', 0
msg_t9_b_ok	db	'AH=41h on directory succeeded', 0
msg_t9_b_ax	db	'wrong AX for AH=41h dir reject', 0
msg_t9_b_gone	db	'T9DIR disappeared after rejected DEL', 0
msg_t9_c_ok	db	'AH=41h on RO file succeeded', 0
msg_t9_c_ax	db	'wrong AX for AH=41h RO reject', 0
msg_t9_d_ok	db	'AH=3Ch on RO file succeeded', 0
msg_t9_d_ax	db	'wrong AX for AH=3Ch RO reject', 0
msg_t9_e_ok	db	'AH=3Dh write on RO file succeeded', 0
msg_t9_e_ax	db	'wrong AX for AH=3Dh RO-write reject', 0
msg_t9_f_ro_read db	'AH=3Dh read on RO file failed', 0

msg_t10		db	'T10 seek-EOF append at cluster bound: ', 0
msg_t10_io	db	'io', 0
msg_t10_seek	db	'seek to EOF returned wrong position', 0
msg_t10_size	db	'file size after append wrong', 0
msg_t10_content	db	'content mismatch (byte 0 trampled?)', 0

msg_t11		db	'T11 AH=40h CX=0 truncate frees chain: ', 0
msg_t11_io	db	'io', 0
msg_t11_disk	db	'get-free-space failed', 0
msg_t11_a_write	db	'write 3072 bytes failed', 0
msg_t11_a_trunc	db	'AH=40 CX=0 truncate-to-zero failed', 0
msg_t11_a_size	db	'size after truncate-to-zero != 0', 0
msg_t11_a_leak	db	'truncate-to-zero leaked clusters', 0
msg_t11_b_write	db	'rewrite 3072 bytes failed', 0
msg_t11_b_trunc	db	'AH=40 CX=0 partial truncate failed', 0
msg_t11_b_size	db	'size after partial truncate != 1000', 0
msg_t11_b_leak	db	'partial truncate kept wrong cluster count', 0
msg_t11_c_write	db	'part C write 3072 bytes failed', 0
msg_t11_c_trunc	db	'part C truncate failed', 0
msg_t11_c_append db	'append after truncate failed', 0
msg_t11_c_size	db	'size after truncate+append wrong', 0
msg_t11_c_content db	'content after truncate+append wrong (freed cluster reused?)', 0

msg_t12		db	'T12 AH=56h rename guards dest: ', 0
msg_t12_io	db	'setup io', 0
msg_t12_a_ok	db	'rename to existing dst returned success', 0
msg_t12_a_ax	db	'wrong AX for duplicate-dst reject', 0
msg_t12_a_src_gone db	'source disappeared after rejected rename', 0
msg_t12_a_dst_gone db	'destination disappeared after rejected rename', 0
msg_t12_a_duplicate db	'duplicate dir entry left behind', 0
msg_t12_b_same_failed db 'same-name rename was rejected', 0
msg_t12_b_lost	db	'file disappeared after same-name rename', 0
msg_t12_c_ok	db	'rename to \\path returned success', 0
msg_t12_c_ax	db	'wrong AX for \\path reject', 0
msg_t12_c_ok2	db	'rename to A: returned success', 0
msg_t12_c_ax2	db	'wrong AX for A: reject', 0
msg_t12_c_src_gone db	'source disappeared after rejected path rename', 0
msg_t12_d_ok	db	'rename MISSING -> MISSING returned success', 0
msg_t12_d_ax	db	'wrong AX for MISSING -> MISSING (want 2)', 0
msg_t12_e_ok	db	'rename MISSING -> EXISTING returned success', 0
msg_t12_e_ax	db	'wrong AX for MISSING -> EXISTING (want 2)', 0
msg_t12_e_dst_gone db	'destination disappeared after rejected MISSING rename', 0
msg_t12_f_failed db	'positive-path A -> B rename failed', 0
msg_t12_f_src_remains db 'source still exists after successful rename', 0
msg_t12_f_dst_missing db 'destination not present after successful rename', 0

msg_t13		db	'T13 DUP alias not overwritten by open: ', 0
msg_t13_io	db	'setup io', 0
msg_t13_dup	db	'AH=45 DUP failed', 0
msg_t13_collision db	'open(B) returned the dup-aliased handle', 0
msg_t13_dup_read db	'read through dup handle failed', 0
msg_t13_dup_content db	'dup handle no longer points at T13A', 0
msg_t13_b_read	db	'read through new handle failed', 0
msg_t13_b_content db	'new handle no longer points at T13B', 0
msg_t13_b_io	db	'AH=3C create T13C failed', 0
msg_t13_b_collision db	'AH=3C create returned the dup-aliased handle', 0
msg_t13_b_dup_read db	're-read through dup handle after AH=3C failed', 0
msg_t13_b_dup_content db 'dup handle clobbered by AH=3C create', 0

msg_t14		db	'T14 empty/path-only create rejected: ', 0
msg_t14_3c_empty db	'AH=3C "" returned success', 0
msg_t14_3c_root db	'AH=3C "\\" returned success', 0
msg_t14_39_empty db	'AH=39 "" returned success', 0
msg_t14_39_root db	'AH=39 "\\" returned success', 0
msg_t14_real	db	'sane AH=3C create regressed', 0

msg_t15		db	'T15 child term closes std handles: ', 0
msg_t15_chdir	db	'CHDIR \TEST failed', 0
msg_t15_resize	db	'AH=4A shrink failed', 0
msg_t15_exec	db	'EXEC T15CHLD failed', 0
msg_t15_size_call db	'AH=3D/42 on T15.TMP failed', 0
msg_t15_size	db	'T15.TMP size != 4 (sft_finalize skipped?)', 0

msg_t16		db	'T16 DIV/IDIV overflow fires INT 0: ', 0
msg_t16_c1	db	'unsigned byte DIV $FFFF/1 missed INT 0', 0
msg_t16_c2_fired db	'unsigned byte DIV $FF/2 spurious INT 0', 0
msg_t16_c2_quot	db	'unsigned byte DIV quotient wrong', 0
msg_t16_c2_rem	db	'unsigned byte DIV remainder wrong', 0
msg_t16_c3	db	'unsigned word DIV $10000/1 missed INT 0', 0
msg_t16_c4	db	'signed byte IDIV +128/1 missed INT 0', 0
msg_t16_c5_fired db	'signed byte IDIV -128/1 spurious INT 0', 0
msg_t16_c5_quot	db	'signed byte IDIV -128 quotient wrong', 0

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

fn_t7a		db	'T7A.TMP', 0
fn_t7b		db	'T7B.TMP', 0
fn_t7c		db	'T7C.TMP', 0
t7_pattern	db	'\TEST\T7?.TMP', 0
t7_count	dw	0
t7_dta		times 43 db 0

fn_t8		db	'T8.TMP', 0

fn_t9		db	'T9.TMP', 0
fn_t9dir	db	'T9DIR', 0
fn_root		db	'\', 0

fn_t10		db	'T10.TMP', 0
fn_t11		db	'T11.TMP', 0
fn_t12a		db	'T12A.TMP', 0
fn_t12b		db	'T12B.TMP', 0
fn_t12c		db	'T12C.TMP', 0
fn_t12d		db	'T12D.TMP', 0
fn_t12e		db	'T12E.TMP', 0
fn_t12f		db	'T12F.TMP', 0
fn_t12g		db	'T12G.TMP', 0
fn_t12_missing	db	'T12NOPE.TMP', 0

fn_t13a		db	'T13A.TMP', 0
fn_t13b		db	'T13B.TMP', 0
fn_t13c		db	'T13C.TMP', 0
t13_a_seed	db	'A'
t13_b_seed	db	'B'

fn_t14_empty	db	0
fn_t14_root	db	'\', 0
fn_t14_real	db	'T14.TMP', 0

fn_t15_child	db	'T15CHLD.COM', 0
fn_t15_tmp	db	'T15.TMP', 0
t15_cmdtail	db	0, 0x0D			; empty cmd tail (length=0, CR)
t15_exec_pb	times 14 db 0

t16_div0_flag	db	0
t16_orig_off	dw	0
t16_orig_seg	dw	0
fn_t12bad_path	db	'\T12X.TMP', 0
fn_t12bad_drive	db	'A:T12X.TMP', 0

t2_data		db	'HELLO'
t4_seed		db	'SEED'

pass_count	dw	0
t1_handle	dw	0
t2_handle	dw	0
t3_handle	dw	0
t4_handle	dw	0
t5_a_handle	dw	0
t5_b_handle	dw	0
t8_handle	dw	0
t9_handle	dw	0
t10_handle	dw	0
t11_handle	dw	0
t13_h_a		dw	0
t13_h_dup	dw	0
t13_h_b		dw	0
t11_free_baseline dw	0
t3_free_before	dw	0
t3_free_populated dw	0

io_buf:		times 2048 db 0
