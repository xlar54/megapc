; T15CHLD.COM — child program for FIXTEST T15.
;
; Creates T15.TMP for write, DUP2's the file handle onto stdout
; (handle 1) without closing the alias, writes 4 bytes through the
; aliased stdout, then exits WITHOUT closing anything. term_common
; in the parent must close handles 0..MAX (not just 5+) so that the
; DUP2'd file alias gets dropped, the SFT refcount reaches zero,
; and sft_finalize writes the new size back to the dir entry.
;
; If the parent's term_common only closes 5+ (pre-fix), the alias
; on JFT[1] is leaked, refcount stays nonzero, sft_finalize never
; runs, and the dir entry's file size remains 0.

	cpu	8086
	org	0x0100

	mov	ah, 0x3C		; Create T15.TMP
	xor	cx, cx
	mov	dx, fname
	int	0x21
	jc	.die			; create failed — give up gracefully

	mov	bx, ax			; BX = file handle (source for DUP2)
	mov	cx, 1			; CX = target handle (stdout)
	mov	ah, 0x46		; DUP2
	int	0x21

	mov	bx, 1			; Write through stdout (now → file)
	mov	cx, 4
	mov	dx, payload
	mov	ah, 0x40
	int	0x21

	; Deliberately do NOT close anything — the whole point is to
	; verify that the parent's termination cleanup walks 0..MAX.
.die:
	mov	ax, 0x4C00
	int	0x21

fname	db	'T15.TMP', 0
payload	db	'LEAK'
