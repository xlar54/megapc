; FWRITE.COM — creates and writes a file using INT 21h
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Create file
	mov	ah, 0x3C
	mov	cx, 0		; Normal attributes
	mov	dx, fname
	int	0x21
	jc	error
	mov	[handle], ax

	; Write message to file
	mov	ah, 0x40
	mov	bx, [handle]
	mov	cx, msg_len
	mov	dx, msg
	int	0x21
	jc	close_error

	; Close file
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	; Print confirmation to stdout
	mov	ah, 0x40
	mov	bx, 1		; stdout
	mov	cx, ok_len
	mov	dx, ok_msg
	int	0x21

	; Terminate
	mov	ax, 0x4C00
	int	0x21

close_error:
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

error:
	mov	ah, 0x09
	mov	dx, errmsg
	int	0x21
	mov	ax, 0x4C01
	int	0x21

fname	db	'OUTPUT.TXT', 0
msg	db	'This file was created by FWRITE.COM!', 0x0D, 0x0A
	db	'MegaDOS file I/O works!', 0x0D, 0x0A
msg_len	equ	$ - msg
ok_msg	db	'File written successfully!', 0x0D, 0x0A
ok_len	equ	$ - ok_msg
errmsg	db	'Error!$'
handle	dw	0
