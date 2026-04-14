; HELLO.EXE code portion — assembled at org 0
; Header is prepended by the build script
	cpu	8086
	org	0

start:
	mov	ah, 0x09
	mov	dx, msg
	int	0x21

	mov	ah, 0x4C
	mov	al, 0
	int	0x21

msg	db	'Hello from an EXE file!', 0x0D, 0x0A, '$'
