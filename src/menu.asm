; ============================================================================
; menu.asm — Disk Mount Menu System
; ============================================================================
;
; Provides an interactive menu for mounting/unmounting floppy disk images
; to Drive A or Drive B before starting emulation. TAB during emulation
; returns to this menu.
;
; Menu requires IRQs enabled (cli) for CHROUT.

; State flag: nonzero if emulation has been started at least once
menu_emu_started .byte 0

; ============================================================================
; show_menu — Display the main menu and handle input
; ============================================================================
show_menu:
        ; Reset charset to default before enabling IRQs
        ; (VIC-IV charset registers are not behind the unlock gate)
        lda #$00
        sta $D068
        lda #$10
        sta $D069
        lda #$00
        sta $D06A

        ; Enable IRQs for CHROUT
        cli

        ; Re-unlock VIC-IV (may have been reset by Hyppo)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031               ; 40MHz
        lda #$80
        tsb VIC_HOTREGS         ; Disable hot registers

        ; Re-init KERNAL screen editor (Hyppo may have trashed it)
        ; Call CINT twice with VIC unlock between — large file loads
        ; can leave VIC-IV in a state that needs double reset
        jsr $FF81               ; CINT — first pass

        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        jsr $FF81               ; CINT — second pass

        ; Re-unlock VIC-IV again (CINT may reset it)
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        ; Clear screen
        lda #147
        jsr CHROUT
        lda #$00
        sta $D020
        sta $D021
        lda #5                  ; White text
        jsr CHROUT

        ; Switch to lowercase character set
        lda #$0E
        jsr CHROUT

        ; CINT + CHROUT $0E above restore the default PETSCII charset

        ; Print menu header
        ldx #0
-       lda menu_header,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; --- Emulation Options ---
        ldx #0
-       lda menu_emu_hdr,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; [1] - Start or Restart
        lda menu_emu_started
        bne _menu_show_restart
        ldx #0
-       lda menu_start_txt,x
        beq _menu_opt1_done
        jsr CHROUT
        inx
        bne -
        bra _menu_opt1_done
_menu_show_restart:
        ldx #0
-       lda menu_restart_txt,x
        beq _menu_opt1_done
        jsr CHROUT
        inx
        bne -
_menu_opt1_done:

        ; [2] - Resume (show unavailable if not running)
        lda menu_emu_started
        bne _menu_show_resume
        ldx #0
-       lda menu_resume_na_txt,x
        beq _menu_opt2_done
        jsr CHROUT
        inx
        bne -
        bra _menu_opt2_done
_menu_show_resume:
        ldx #0
-       lda menu_resume_txt,x
        beq _menu_opt2_done
        jsr CHROUT
        inx
        bne -
_menu_opt2_done:

        ; [X] - Quit
        ldx #0
-       lda menu_quit_txt,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; --- Drive Options ---
        ldx #0
-       lda menu_drv_hdr,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; [A] - Mount or Unmount Drive A
        lda floppy_a_loaded
        bne _menu_show_unmount_a
        ldx #0
-       lda menu_mount_a_txt,x
        beq _menu_opta_done
        jsr CHROUT
        inx
        bne -
        bra _menu_opta_done
_menu_show_unmount_a:
        ldx #0
-       lda menu_unmount_a_txt,x
        beq _menu_opta_done
        jsr CHROUT
        inx
        bne -
_menu_opta_done:

        ; [B] - Mount or Unmount Drive B
        lda floppy_b_loaded
        bne _menu_show_unmount_b
        ldx #0
-       lda menu_mount_b_txt,x
        beq _menu_optb_done
        jsr CHROUT
        inx
        bne -
        bra _menu_optb_done
_menu_show_unmount_b:
        ldx #0
-       lda menu_unmount_b_txt,x
        beq _menu_optb_done
        jsr CHROUT
        inx
        bne -
_menu_optb_done:

        ; --- Special Keys ---
        ldx #0
-       lda menu_keys_hdr,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; Drain keyboard queue
        lda #$00
        sta $D610

        ; Wait for keypress
_menu_wait_key:
        lda $D610
        beq _menu_wait_key
        sta $D610               ; Dequeue
        cmp #'1'
        beq menu_do_start
        cmp #'2'
        beq menu_do_resume
        cmp #$78                ; 'x' lowercase
        beq menu_do_quit
        cmp #$58                ; 'X' uppercase
        beq menu_do_quit
        cmp #$61                ; 'a' lowercase
        beq menu_do_drive_a
        cmp #$41                ; 'A' uppercase
        beq menu_do_drive_a
        cmp #$62                ; 'b' lowercase
        beq menu_do_drive_b
        cmp #$42                ; 'B' uppercase
        beq menu_do_drive_b
        bra _menu_wait_key

menu_do_start:
        ; Start or Restart emulation
        lda menu_emu_started
        beq _menu_first_start
        ; Restart: re-init everything
        lda #0
        sta menu_emu_started
        sta scr_row
        sta scr_col
_menu_first_start:
        lda #1
        sta menu_emu_started
        jmp start_emulation

menu_do_resume:
        ; Resume — only if running
        lda menu_emu_started
        beq show_menu           ; Not running, redraw menu
        jmp resume_emulation

menu_do_drive_a:
        ; Drive A: mount or unmount
        lda floppy_a_loaded
        beq menu_mount_drive_var_a
        ; Unmount Drive A
        lda #0
        sta floppy_a_loaded
        ldx #0
-       lda msg_unmounted,x
        beq +
        jsr CHROUT
        inx
        bne -
+       jsr menu_press_any_key
        jmp show_menu

menu_mount_drive_var_a:
        lda #0                  ; Drive A
        jsr menu_do_mount_fn
        jmp show_menu

menu_do_drive_b:
        ; Drive B: mount or unmount
        lda floppy_b_loaded
        beq menu_mount_drive_var_b
        ; Unmount Drive B
        lda #0
        sta floppy_b_loaded
        ldx #0
-       lda msg_unmounted,x
        beq +
        jsr CHROUT
        inx
        bne -
+       jsr menu_press_any_key
        jmp show_menu

menu_mount_drive_var_b:
        lda #1                  ; Drive B
        jsr menu_do_mount_fn
        jmp show_menu

menu_do_quit:
        ; Quit emulator — warm boot MEGA65 via Hyppo
        lda #$7E
        sta $D640
        clv

; ============================================================================
; menu_do_mount_fn — Prompt for filename and load floppy image
; ============================================================================
; Input: A = drive number (0=A, 1=B)
;
menu_mount_drive_var .byte 0

menu_do_mount_fn:
        sta menu_mount_drive_var

        ; Print filename prompt
        lda #$0D
        jsr CHROUT
        ldx #0
-       lda msg_filename,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; Read filename from keyboard
        jsr menu_read_filename
        ; Check if user entered anything
        lda floppy_fname_page
        beq _menu_mount_cancel  ; Empty filename, cancel

        ; Print loading message
        lda #$0D
        jsr CHROUT
        ldx #0
-       lda msg_loading,x
        beq +
        jsr CHROUT
        inx
        bne -
+

        ; Load the file
        lda menu_mount_drive_var
        jsr load_floppy_drive
        bcc _menu_mount_error

        ; Re-unlock VIC-IV after Hyppo
        lda #$47
        sta VIC_KEY
        lda #$53
        sta VIC_KEY
        lda #$40
        tsb $D031
        lda #$80
        tsb VIC_HOTREGS

        ; Success
        lda #$0D
        jsr CHROUT
        ldx #0
-       lda msg_mounted,x
        beq +
        jsr CHROUT
        inx
        bne -
+       jsr menu_press_any_key

        rts

_menu_mount_error:
        lda #$0D
        jsr CHROUT
        ldx #0
-       lda msg_disk_error,x
        beq +
        jsr CHROUT
        inx
        bne -
+       jsr menu_press_any_key
_menu_mount_cancel:
        rts

; ============================================================================
; menu_read_filename — Read filename input from keyboard
; ============================================================================
; Output: floppy_fname_page filled with null-terminated filename
; Max 63 characters. Enter ($0D) submits. Backspace ($14) deletes.
;
menu_fname_len .byte 0

menu_read_filename:
        lda #0
        sta menu_fname_len

        ; Drain keyboard queue
        sta $D610

_mrf_loop:
        lda $D610
        beq _mrf_loop
        sta $D610               ; Dequeue

        cmp #$0D                ; Enter
        beq _mrf_done

        cmp #$14                ; MEGA65 backspace (DELETE)
        beq _mrf_backspace

        cmp #$1B                ; Escape
        beq _mrf_cancel

        ; Printable character check ($20-$7E)
        cmp #$20
        bcc _mrf_loop           ; Control char, ignore
        cmp #$7F
        bcs _mrf_loop           ; High chars, ignore

        ; Check length limit
        ldx menu_fname_len
        cpx #63
        bcs _mrf_loop           ; At max length

        ; Store character
        sta floppy_fname_page,x
        inc menu_fname_len

        ; Echo character via CHROUT
        jsr CHROUT
        bra _mrf_loop

_mrf_backspace:
        lda menu_fname_len
        beq _mrf_loop           ; Nothing to delete
        dec menu_fname_len
        ; Remove from buffer
        ldx menu_fname_len
        lda #0
        sta floppy_fname_page,x
        ; Visual backspace: cursor left + space + cursor left
        lda #$9D                ; PETSCII cursor left
        jsr CHROUT
        lda #$20                ; Space
        jsr CHROUT
        lda #$9D                ; PETSCII cursor left
        jsr CHROUT
        bra _mrf_loop

_mrf_cancel:
        ; Clear filename
        lda #0
        sta floppy_fname_page
        sta menu_fname_len
_mrf_done:
        ; Null-terminate
        ldx menu_fname_len
        lda #0
        sta floppy_fname_page,x
        rts

; ============================================================================
; menu_press_any_key — Wait for any keypress
; ============================================================================
menu_press_any_key:
        lda #$0D
        jsr CHROUT
        ldx #0
-       lda msg_press_key,x
        beq +
        jsr CHROUT
        inx
        bne -
+
        lda #$00
        sta $D610               ; Drain queue
_mpak_wait:
        lda $D610
        beq _mpak_wait
        sta $D610               ; Dequeue
        rts

; ============================================================================
; menu_tab_handler — Called when TAB is pressed during emulation
; ============================================================================
; Saves screen RAM to attic, enables IRQs, shows menu.
;
menu_tab_handler:
        ; Hide sprite cursor before saving screen
        jsr cursor_hide

        ; Save ZP state (KERNAL IRQs trash $90-$FA)
        ; Save all of ZP $00-$FF to $8F00 area (non-ZP RAM)
        ldx #0
_tab_save_zp:
        lda $00,x
        sta $7F00,x             ; Save to $7F00-$7FFF
        inx
        bne _tab_save_zp

        ; Save screen RAM to attic via DMA
        jsr menu_save_screen

        ; Enable IRQs for CHROUT
        cli

        ; Show menu
        jmp show_menu

; ============================================================================
; menu_save_screen — DMA screen RAM to SCREEN_SAVE_ATTIC
; ============================================================================
menu_save_screen:
        ; Save screen RAM (2000 bytes from $0800)
        lda #<SCREEN_BASE
        sta dma_src_lo
        lda #>SCREEN_BASE
        sta dma_src_hi
        lda #$00
        sta dma_src_bank

        lda #$00
        sta dma_dst_lo
        sta dma_dst_hi
        lda #$30                ; SCREEN_SAVE_ATTIC = $8300000
        sta dma_dst_bank

        lda #<2000
        sta dma_count_lo
        lda #>2000
        sta dma_count_hi
        jsr do_dma_to_attic

        ; Save color RAM (2000 bytes from $1F800)
        lda #$00
        sta dma_src_lo
        lda #$F8
        sta dma_src_hi
        lda #$01
        sta dma_src_bank        ; $1F800

        lda #$D0                ; Offset $D00 into save area (after 2000 bytes of screen)
        sta dma_dst_lo
        lda #$07
        sta dma_dst_hi
        lda #$30
        sta dma_dst_bank        ; $83007D0

        lda #<2000
        sta dma_count_lo
        lda #>2000
        sta dma_count_hi
        jsr do_dma_to_attic
        rts

; ============================================================================
; menu_restore_screen — DMA SCREEN_SAVE_ATTIC back to screen RAM
; ============================================================================
menu_restore_screen:
        ; Restore screen RAM
        lda #$00
        sta dma_src_lo
        sta dma_src_hi
        lda #$30
        sta dma_src_bank

        lda #<SCREEN_BASE
        sta dma_dst_lo
        lda #>SCREEN_BASE
        sta dma_dst_hi
        lda #$00
        sta dma_dst_bank

        lda #<2000
        sta dma_count_lo
        lda #>2000
        sta dma_count_hi
        jsr do_dma_from_attic

        ; Restore color RAM
        lda #$D0
        sta dma_src_lo
        lda #$07
        sta dma_src_hi
        lda #$30
        sta dma_src_bank

        lda #$00
        sta dma_dst_lo
        lda #$F8
        sta dma_dst_hi
        lda #$01
        sta dma_dst_bank        ; $1F800

        lda #<2000
        sta dma_count_lo
        lda #>2000
        sta dma_count_hi
        jsr do_dma_from_attic
        rts

; ============================================================================
; Menu strings
; ============================================================================
menu_header:
        .text 13
        .text "MegaPC - 8086 PC Emulator", 13
        .text "By Scott Hutter - xlar54", 13, 0

hex_tbl:
        .text "0123456789ABCDEF"

menu_emu_hdr:
        .text 13
        .text "Emulation Options:", 13
        .text "--------------------------------------", 13, 0

menu_start_txt:
        .text "[1] - Start Emulation", 13, 0

menu_restart_txt:
        .text "[1] - Restart Emulation", 13, 0

menu_resume_txt:
        .text "[2] - Resume Emulation", 13, 0

menu_resume_na_txt:
        .text "[2] - Resume Emulation (unavailable)", 13, 0

menu_quit_txt:
        .text "[X] - Quit Emulator", 13, 0

menu_drv_hdr:
        .text 13
        .text "Drive Options:", 13
        .text "--------------------------------------", 13, 0

menu_mount_a_txt:
        .text "[A] - Mount Drive A", 13, 0

menu_unmount_a_txt:
        .text "[A] - Unmount Drive A", 13, 0

menu_mount_b_txt:
        .text "[B] - Mount Drive B", 13, 0

menu_unmount_b_txt:
        .text "[B] - Unmount Drive B", 13, 0

menu_keys_hdr:
        .text 13
        .text "Special Keys While In Emulation:", 13
        .text "--------------------------------------", 13
        .text "[TAB] - Return to this menu", 13, 0

msg_filename:
        .text "Filename: ", 0

msg_loading:
        .text "Loading...", 0

msg_mounted:
        .text "Disk Mounted.", 0

msg_unmounted:
        .text 13, "Disk unmounted (changes not saved).", 0

msg_disk_error:
        .text "Disk Read Error", 0

msg_press_key:
        .text "Press any key...", 0
