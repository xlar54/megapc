; TEST.COM — asks for name and greets the user
; Uses INT 21h services (runs under Simple OS)

	cpu	8086
	org	0x0100

	; Print prompt
	mov	ah, 0x09
	mov	dx, msg_prompt
	int	0x21

	; Read name using buffered input (AH=0A)
	mov	ah, 0x0A
	mov	dx, input_buf
	int	0x21

	; Print greeting
	mov	ah, 0x09
	mov	dx, msg_hello
	int	0x21

	; Print the name from input buffer
	; input_buf+2 = start of text, input_buf+1 = length
	mov	cl, [input_buf+1]
	xor	ch, ch
	jcxz	.name_done
	mov	si, input_buf+2
.print_name:
	lodsb
	mov	dl, al
	mov	ah, 0x02
	int	0x21
	dec	cx
	jnz	.print_name
.name_done:

	; Print newline
	mov	ah, 0x09
	mov	dx, msg_crlf
	int	0x21

	; Terminate
	mov	ah, 0x4C
	mov	al, 0
	int	0x21

msg_prompt	db	'What is your name? $'
msg_hello	db	0x0D, 0x0A, 'Hello, $'
msg_crlf	db	0x0D, 0x0A, '$'

input_buf	db	32		; Max length
		db	0		; Actual length (filled by DOS)
		times 33 db 0		; Data area
