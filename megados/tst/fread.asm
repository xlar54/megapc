; FREAD.COM — reads and displays a file using INT 21h file I/O
; Usage: FREAD (reads README.TXT)
	cpu	8086
	org	0x0100

	push	cs
	pop	ds

	; Open README.TXT
	mov	ah, 0x3D
	mov	al, 0		; Read mode
	mov	dx, fname
	int	0x21
	jc	error
	mov	[handle], ax

	; Read loop
read_loop:
	mov	ah, 0x3F
	mov	bx, [handle]
	mov	cx, 128		; Read 128 bytes at a time
	mov	dx, buffer
	int	0x21
	jc	error
	cmp	ax, 0		; EOF?
	je	done

	; Print what we read
	mov	cx, ax		; Bytes read
	mov	bx, 1		; stdout
	mov	dx, buffer
	mov	ah, 0x40
	int	0x21

	jmp	read_loop

done:
	; Close file
	mov	ah, 0x3E
	mov	bx, [handle]
	int	0x21

	; Terminate
	mov	ah, 0x4C
	mov	al, 0
	int	0x21

error:
	mov	ah, 0x09
	mov	dx, errmsg
	int	0x21
	mov	ah, 0x4C
	mov	al, 1
	int	0x21

fname	db	'README.TXT', 0
errmsg	db	'Error opening file$'
handle	dw	0
buffer	times 128 db 0
