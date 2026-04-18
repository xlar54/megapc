; BEEP.COM - Test PC speaker emulation
; Plays several tones using PIT Timer 2 + port $61
; Build: nasm -f bin -o beep.com beep.asm

org 100h

start:
    mov dx, msg_start
    mov ah, 09h
    int 21h

    ; === Tone 1: 440 Hz (A4) ===
    mov dx, msg_440
    mov ah, 09h
    int 21h
    mov bx, 2712            ; 1193182 / 440 = 2712
    call play_tone
    call wait_key

    ; === Tone 2: 523 Hz (C5) ===
    mov dx, msg_523
    mov ah, 09h
    int 21h
    mov bx, 2281            ; 1193182 / 523
    call play_tone
    call wait_key

    ; === Tone 3: 659 Hz (E5) ===
    mov dx, msg_659
    mov ah, 09h
    int 21h
    mov bx, 1810            ; 1193182 / 659
    call play_tone
    call wait_key

    ; === Tone 4: 880 Hz (A5) ===
    mov dx, msg_880
    mov ah, 09h
    int 21h
    mov bx, 1356            ; 1193182 / 880
    call play_tone
    call wait_key

    ; === Tone 5: 1000 Hz ===
    mov dx, msg_1000
    mov ah, 09h
    int 21h
    mov bx, 1193            ; 1193182 / 1000
    call play_tone
    call wait_key

    ; === Tone 6: 2000 Hz ===
    mov dx, msg_2000
    mov ah, 09h
    int 21h
    mov bx, 597             ; 1193182 / 2000
    call play_tone
    call wait_key

    ; Speaker off
    call speaker_off

    mov dx, msg_done
    mov ah, 09h
    int 21h

    mov ah, 4Ch
    int 21h

; Set PIT Timer 2 frequency and turn speaker on
; Input: BX = PIT divider value
play_tone:
    ; Set PIT Timer 2, mode 3 (square wave), binary
    mov al, 0B6h
    out 43h, al
    ; Set frequency divider
    mov al, bl
    out 42h, al
    mov al, bh
    out 42h, al
    ; Turn speaker on (bits 0+1 of port 61h)
    in al, 61h
    or al, 03h
    out 61h, al
    ret

speaker_off:
    in al, 61h
    and al, 0FCh
    out 61h, al
    ret

wait_key:
    mov ah, 00h
    int 16h
    call speaker_off
    mov dl, 0Dh
    mov ah, 02h
    int 21h
    mov dl, 0Ah
    mov ah, 02h
    int 21h
    ret

msg_start db 'PC Speaker Test - press key for each tone', 0Dh, 0Ah, '$'
msg_440   db '440 Hz (A4): ', '$'
msg_523   db '523 Hz (C5): ', '$'
msg_659   db '659 Hz (E5): ', '$'
msg_880   db '880 Hz (A5): ', '$'
msg_1000  db '1000 Hz:     ', '$'
msg_2000  db '2000 Hz:     ', '$'
msg_done  db 'Done!', 0Dh, 0Ah, '$'
