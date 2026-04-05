**MegaPC 8086 PC XT Emulator**

This is a simple DOS 8086 emulator for the Mega65 computer,
with 640kb of RAM, and an A and B floppy drive.

***Usage***
Place disk images on your sd-card in the root, named in ALL CAPS.  After that, its pretty self explanatory.  It will handle disks
of varying sizes (160k, 180k, 320k, 360k, 720k, 1.44MB)

The source code has a core switch from MDA to CGA but implementing
this fully is low priority.

Different version of DOS give mixed results. Im working on improving. Please leave issues as you may find them.

***Known issues***
* Freedos does some decompression and writing to higher ram, and is initially slow in loading.  Be patient.

* Due to the bios implementations, some dos disks may work, others - especially OEM versions - may not.

* CGA is in the code, available by switching VIDEO_MODE.  I didnt bother creating a switch in the menu as Im focused more on accuracy with monochrome first.

* The emulator uses the Mega65 characterset that is IBM-like. I believe some chars are still not translated properly.  Eventually we may implement a true codepage 37 characterset.

***Building***
I use 64TASS - a terrific cross platform assembler.  Just copy down the repo, run build.bat from the DOS command prompt and it should generate a d81 in the target folder.  You also need NASM installed in order to build the bios.bin file.

***credits***
Modified Tiny86 bios source from https://github.com/xrip/tiny8086-sdl2-win32/tree/main

ClaudeAI for much else



