; CHILD.COM — tiny child program for EXEC test
; Exits with return code 42 (0x2A)
	cpu	8086
	org	0x0100

	mov	ax, 0x4C2A		; Exit with code 42
	int	0x21
