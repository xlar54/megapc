**MegaPC 8086 PC XT Emulator**

This is a simple DOS 8086 emulator for the Mega65 computer,
with 640kb of RAM, and an A and B floppy drive.

Place disk images on your sd-card in the root, named in ALL CAPS.  After that, its pretty self explanatory.  It will handle disks
of varying sizes (160k, 180k, 320k, 360k, 720k, 1.44MB)

The source code has a core switch from MDA to CGA but implementing
this fully is low priority.

Different version of DOS give mixed results. Im working on improving. Please leave issues as you may find them.

Known issues:
* Freedos does some decompression and writing to higher ram, and seems to have an issue.  Working on this.

* MS-DOS 3.3 (the standard Im aiming to fully support) also has an issue on how it outputs some commands to screen.  DIR and ECHO seem to print empty spaces.  This one is high priority.

Due to bios implementations, some dos disks may work, others - especially OEM versions - may not.




