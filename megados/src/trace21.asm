; TRACE21.COM — hooks INT 21h, logs AH values, then runs GWBASIC
; After GWBASIC exits, displays the log
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Save original INT 21h vector
	mov	ax, 0x3521
	int	0x21
	mov	[old21_off], bx
	mov	[old21_seg], es

	; Install our hook
	mov	ax, 0x2521
	mov	dx, hook21
	int	0x21

	; Reset log
	mov	word [log_pos], 0

	; Print message
	mov	ah, 0x09
	mov	dx, msg_start
	int	0x21

	; Open GWBASIC.EXE and read it ourselves? No — just exec it
	; Actually we can't EXEC (AH=4B) since MegaDOS doesn't support it
	; Instead, let's just call various INT 21h functions that GWBASIC
	; would call and see which ones fail

	; Simulate GWBASIC's early calls:

	; 1. AH=4A resize to FFFF
	mov	ah, 0x09
	mov	dx, msg_4a
	int	0x21
	mov	bx, 0xFFFF
	mov	ah, 0x4A
	int	0x21
	; Should fail with CF=1, BX=max
	jc	.4a_ok
	mov	ah, 0x09
	mov	dx, msg_noerr
	int	0x21
	jmp	.4a_done
.4a_ok:
	push	bx
	mov	ah, 0x09
	mov	dx, msg_cf1
	int	0x21
	pop	ax
	call	print_hex
.4a_done:
	call	newline

	; 2. AH=4A resize to returned BX
	mov	ah, 0x09
	mov	dx, msg_4a2
	int	0x21
	; BX still has max from above... but it was popped into AX
	; Redo: get max again
	mov	bx, 0xFFFF
	mov	ah, 0x4A
	int	0x21
	; Now BX = max
	push	bx
	mov	ah, 0x4A
	int	0x21
	jc	.4a2_err
	mov	ah, 0x09
	mov	dx, msg_ok
	int	0x21
	jmp	.4a2_done
.4a2_err:
	mov	ah, 0x09
	mov	dx, msg_cf1
	int	0x21
.4a2_done:
	pop	ax
	call	print_hex
	call	newline

	; 3. AH=37 AL=0 get switch char
	mov	ah, 0x09
	mov	dx, msg_37
	int	0x21
	mov	ax, 0x3700
	int	0x21
	mov	al, dl
	xor	ah, ah
	call	print_hex
	call	newline

	; 4. AH=30 get DOS version
	mov	ah, 0x09
	mov	dx, msg_30
	int	0x21
	mov	ah, 0x30
	int	0x21
	push	ax
	xor	ah, ah
	call	print_hex
	mov	dl, '.'
	mov	ah, 0x02
	int	0x21
	pop	ax
	mov	al, ah
	xor	ah, ah
	call	print_hex
	call	newline

	; 5. AH=35 get INT 08h
	mov	ah, 0x09
	mov	dx, msg_35
	int	0x21
	mov	ax, 0x3508
	int	0x21
	mov	ax, es
	call	print_hex
	mov	dl, ':'
	mov	ah, 0x02
	int	0x21
	mov	ax, bx
	call	print_hex
	call	newline

	; 6. AH=44 AL=0 IOCTL on handle 1
	mov	ah, 0x09
	mov	dx, msg_44
	int	0x21
	mov	ax, 0x4400
	mov	bx, 1
	int	0x21
	jc	.44_err
	mov	ax, dx
	call	print_hex
	jmp	.44_done
.44_err:
	mov	ah, 0x09
	mov	dx, msg_err
	int	0x21
.44_done:
	call	newline

	; 7. AH=19 get current drive
	mov	ah, 0x09
	mov	dx, msg_19
	int	0x21
	mov	ah, 0x19
	int	0x21
	xor	ah, ah
	call	print_hex
	call	newline

	; 8. AH=0D disk reset
	mov	ah, 0x09
	mov	dx, msg_0d
	int	0x21
	mov	ah, 0x0D
	int	0x21
	mov	ah, 0x09
	mov	dx, msg_ok
	int	0x21
	call	newline

	; 9. AH=0E set drive 0
	mov	ah, 0x09
	mov	dx, msg_0e
	int	0x21
	mov	ah, 0x0E
	mov	dl, 0
	int	0x21
	xor	ah, ah
	call	print_hex
	call	newline

	; 10. Test AH=3F on handle 0 (stdin) — non-blocking check
	mov	ah, 0x09
	mov	dx, msg_3f
	int	0x21
	; Skip actual stdin read since it would block

	; 11. Test AH=40 on handle 1 (stdout)
	mov	ah, 0x09
	mov	dx, msg_40
	int	0x21
	mov	ah, 0x40
	mov	bx, 1
	mov	cx, 5
	mov	dx, test_str
	int	0x21
	jc	.40_err
	call	print_hex	; Should show 5
	jmp	.40_done
.40_err:
	mov	ah, 0x09
	mov	dx, msg_err
	int	0x21
.40_done:
	call	newline

	; Restore INT 21h
	push	ds
	mov	ax, 0x2521
	mov	dx, [old21_off]
	mov	ds, [old21_seg]
	int	0x21
	pop	ds

	; Print log
	mov	ah, 0x09
	mov	dx, msg_log
	int	0x21
	mov	cx, [log_pos]
	cmp	cx, 0
	je	.no_log
	mov	si, log_buf
.print_log:
	lodsb
	push	cx
	xor	ah, ah
	call	print_hex
	mov	dl, ' '
	mov	ah, 0x02
	int	0x21
	pop	cx
	dec	cx
	jnz	.print_log
.no_log:
	call	newline

	mov	ax, 0x4C00
	int	0x21

; --- INT 21h hook ---
hook21:
	; Log AH to buffer
	push	bx
	push	ds
	push	cs
	pop	ds
	mov	bx, [log_pos]
	cmp	bx, 255
	jae	.hook_skip
	mov	[log_buf + bx], ah
	inc	word [log_pos]
.hook_skip:
	pop	ds
	pop	bx
	; Chain to original
	jmp	far [cs:old21_off]

; --- Subroutines ---
print_hex:
	push	cx
	push	dx
	mov	cx, 4
.ph:	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	rol	ax, 1
	push	ax
	and	al, 0x0F
	add	al, '0'
	cmp	al, '9'
	jbe	.po
	add	al, 7
.po:	mov	dl, al
	mov	ah, 0x02
	int	0x21
	pop	ax
	dec	cx
	jnz	.ph
	pop	dx
	pop	cx
	ret

newline:
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

; --- Data ---
msg_start db	'=== INT 21h Trace ===', 0x0D, 0x0A, '$'
msg_4a	db	'AH=4A BX=FFFF: ', '$'
msg_4a2	db	'AH=4A BX=max: ', '$'
msg_37	db	'AH=37 switch: ', '$'
msg_30	db	'AH=30 ver: ', '$'
msg_35	db	'AH=35 INT08: ', '$'
msg_44	db	'AH=44 IOCTL: ', '$'
msg_19	db	'AH=19 drive: ', '$'
msg_0d	db	'AH=0D reset: ', '$'
msg_0e	db	'AH=0E setdrv: ', '$'
msg_3f	db	'AH=3F stdin: (skip)', 0x0D, 0x0A, '$'
msg_40	db	'AH=40 write: ', '$'
msg_cf1	db	'CF=1 BX=', '$'
msg_ok	db	'OK', '$'
msg_noerr db	'no error?', '$'
msg_err	db	'ERROR', '$'
msg_log	db	0x0D, 0x0A, 'Log: ', '$'
test_str db	'HELLO'

old21_off dw	0
old21_seg dw	0
log_pos	dw	0
log_buf	times 256 db 0
