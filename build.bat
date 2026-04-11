cls
del target\*.bin
del target\*.d81
del target\*.lst
del target\*.lbl
del target\megapc
nasm -f bin -o target\bios.bin src\bios\bios.asm
64tass --nostart -o target\cp437.bin src\cp437_font.asm
64tass --nostart -l target\ftwriter.lbl -L target\ftwriter.lst -o target\ftwriter.bin src\fat_writer.asm
64tass --cbm-prg -a src\main.asm -l target\megapc.lbl -L target\megapc.lst -o target\megapc
cd target
c1541 -format "megapc,01" d81 megapc.d81
c1541 -attach megapc.d81 -write megapc megapc
c1541 -attach megapc.d81 -write ../target/bios.bin bios.bin
c1541 -attach megapc.d81 -write ../target/cp437.bin cp437.bin
c1541 -attach megapc.d81 -write ../target/ftwriter.bin ftwriter.bin
cd ..
C:\Emulation\Mega65\xmega65.exe -8 C:\Users\scott\repos\megapc\target\megapc.d81 -hdosvirt true -autoload true