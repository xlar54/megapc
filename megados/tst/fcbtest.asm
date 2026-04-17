; FCBTEST.COM — Test FCB sequential read (AH=14)
; Opens README.TXT via FCB, reads first record, prints it
	cpu	8086
	org	0x0100

	; Open file via FCB (AH=0F)
	mov	ah, 0x0F
	mov	dx, fcb
	int	0x21
	cmp	al, 0
	jne	.open_fail

	; Print "Open OK"
	mov	ah, 0x09
	mov	dx, msg_open
	int	0x21

	; Read first record (AH=14)
	mov	ah, 0x14
	mov	dx, fcb
	int	0x21
	cmp	al, 0
	je	.read_ok
	cmp	al, 3
	je	.read_ok		; Partial record is also OK

	; Read failed
	mov	ah, 0x09
	mov	dx, msg_rfail
	int	0x21
	jmp	.done

.read_ok:
	; Print "Read OK"
	mov	ah, 0x09
	mov	dx, msg_read
	int	0x21

	; Print DTA contents (first 64 bytes)
	; Default DTA is at PSP:0x80
	mov	si, 0x0080
	mov	cx, 64
.print_loop:
	lodsb
	cmp	al, 0
	je	.done
	cmp	al, 0x1A		; EOF marker
	je	.done
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.print_loop
	jmp	.done

.open_fail:
	mov	ah, 0x09
	mov	dx, msg_ofail
	int	0x21

.done:
	mov	ah, 0x09
	mov	dx, msg_nl
	int	0x21
	mov	ax, 0x4C00
	int	0x21

msg_open:	db	'Open OK', 13, 10, '$'
msg_read:	db	'Read OK: ', '$'
msg_ofail:	db	'Open FAIL', '$'
msg_rfail:	db	'Read FAIL', '$'
msg_nl:		db	13, 10, '$'

; FCB for README.TXT
fcb:
	db	0			; Drive (0=default)
	db	'README  '		; Filename (8 chars, space-padded)
	db	'TXT'			; Extension (3 chars)
	times 25 db 0			; Rest of FCB (filled by AH=0F)
