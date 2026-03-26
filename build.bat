del target/*.d81
del target/*.lst
del target/*.lbl
del target/megapc
64tass --cbm-prg -a src\main.asm -l target\megapc.lbl -L target\megapc.lst -o target\megapc
cd target
c1541 -format "megapc,01" d81 megapc.d81
c1541 -attach megapc.d81 -write megapc megapc
c1541 -attach megapc.d81 -write ../src/bios.bin bios.bin
cd ..
C:\Emulation\Mega65\xmega65.exe -8 C:\Users\scott\repos\megapc\target\megapc.d81 -hdosvirt true -autoload true