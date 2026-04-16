#!/usr/bin/env python3
"""MegaDOS disk image builder.

Assembles shell and utilities, creates a bootable 360K FAT12 floppy image.
Source files are read from src/, compiled binaries go to target/,
and the final .img is copied to HDOS.
"""

import struct
import subprocess
import os
import sys
import shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(SCRIPT_DIR, 'src')
TARGET_DIR = os.path.join(SCRIPT_DIR, 'target')
HDOS_DIR = os.path.join(os.path.expanduser('~'), 'AppData', 'Roaming',
                        'xemu-lgb', 'mega65', 'hdos')
NASM = os.path.join(SCRIPT_DIR, '..', 'nasm.exe')

# --- Disk geometry (360K) ---
BYTES_PER_SEC = 512
SECS_PER_CLUST = 2
RESERVED_SECS = 1
NUM_FATS = 2
SECS_PER_FAT = 2
ROOT_ENTRIES = 112
TOTAL_SECS = 720
SPT = 9
HEADS = 2
MEDIA_BYTE = 0xFD

ROOT_DIR_START_SEC = RESERVED_SECS + NUM_FATS * SECS_PER_FAT  # 5
ROOT_DIR_SECS = (ROOT_ENTRIES * 32 + BYTES_PER_SEC - 1) // BYTES_PER_SEC  # 7
DATA_START_SEC = ROOT_DIR_START_SEC + ROOT_DIR_SECS  # 12

if os.path.exists(TARGET_DIR):
    shutil.rmtree(TARGET_DIR)
os.makedirs(TARGET_DIR)


def nasm_assemble(src_name, out_name):
    """Assemble a NASM source file to flat binary."""
    src = os.path.join(SRC_DIR, src_name)
    out = os.path.join(TARGET_DIR, out_name)
    if not os.path.exists(src):
        return None
    result = subprocess.run(
        [NASM, '-f', 'bin', '-o', out, src],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"NASM error assembling {src_name}:")
        print(result.stderr)
        sys.exit(1)
    data = open(out, 'rb').read()
    print(f"  {out_name}: {len(data)} bytes")
    return data


# --- Assemble all sources ---
print("Assembling...")
shell_data = nasm_assemble('shell.asm', 'SHELL.COM')
if shell_data is None:
    print("ERROR: src/shell.asm not found")
    sys.exit(1)

# Optional utilities
nasm_assemble('test.asm', 'TEST.COM')
nasm_assemble('fread.asm', 'FREAD.COM')
nasm_assemble('fwrite.asm', 'FWRITE.COM')
nasm_assemble('sysinfo.asm', 'SYSINFO.COM')
nasm_assemble('dirtest.asm', 'DIRTEST.COM')
nasm_assemble('exetest.asm', 'EXETEST.COM')
nasm_assemble('trace21.asm', 'TRACE21.COM')
nasm_assemble('hdltest.asm', 'HDLTEST.COM')
nasm_assemble('dostest.asm', 'DOSTEST.COM')
nasm_assemble('child.asm', 'CHILD.COM')
nasm_assemble('hello.asm', 'hello_code.bin')

# Build HELLO.EXE from hello_code.bin
hello_code_path = os.path.join(TARGET_DIR, 'hello_code.bin')
if os.path.exists(hello_code_path):
    hello_code = open(hello_code_path, 'rb').read()
    # Minimal MZ EXE header (28 bytes, 1 paragraph)
    header = bytearray(32)
    code_size = len(hello_code)
    total_size = 32 + code_size
    pages = (total_size + 511) // 512
    last_page = total_size % 512
    struct.pack_into('<H', header, 0, 0x5A4D)       # MZ signature
    struct.pack_into('<H', header, 2, last_page)      # bytes in last page
    struct.pack_into('<H', header, 4, pages)           # total pages
    struct.pack_into('<H', header, 6, 0)               # no relocations
    struct.pack_into('<H', header, 8, 2)               # header size in paragraphs (32 bytes)
    struct.pack_into('<H', header, 10, 1)              # min extra paragraphs
    struct.pack_into('<H', header, 12, 0xFFFF)         # max extra paragraphs
    struct.pack_into('<H', header, 14, 0)              # SS
    struct.pack_into('<H', header, 16, 0x100)          # SP
    struct.pack_into('<H', header, 20, 0)              # IP
    struct.pack_into('<H', header, 22, 0)              # CS
    struct.pack_into('<H', header, 24, 28)             # reloc table offset
    exe_data = bytes(header) + hello_code
    exe_path = os.path.join(TARGET_DIR, 'HELLO.EXE')
    open(exe_path, 'wb').write(exe_data)
    print(f"  HELLO.EXE: {len(exe_data)} bytes (from hello_code.bin)")
    os.remove(hello_code_path)

# Copy non-assembled files to target
for fname in ['GWBASIC.EXE', 'AUTOEXEC.BAT', 'README.TXT']:
    src = os.path.join(SRC_DIR, fname)
    dst = os.path.join(TARGET_DIR, fname)
    if os.path.exists(src):
        shutil.copy2(src, dst)

# --- Build disk image ---
print("\nBuilding disk image...")

shell_sectors = (len(shell_data) + BYTES_PER_SEC - 1) // BYTES_PER_SEC
shell_clusters = (shell_sectors + SECS_PER_CLUST - 1) // SECS_PER_CLUST
shell_sectors = shell_clusters * SECS_PER_CLUST
print(f"  Shell: {shell_sectors} sectors ({shell_clusters} clusters)")

img = bytearray(TOTAL_SECS * BYTES_PER_SEC)

# --- Boot sector ---
boot = bytearray(512)
boot[0] = 0xEB; boot[1] = 0x3C; boot[2] = 0x90
boot[3:11] = b'MEGADOS '

# BPB
struct.pack_into('<H', boot, 11, BYTES_PER_SEC)
boot[13] = SECS_PER_CLUST
struct.pack_into('<H', boot, 14, RESERVED_SECS)
boot[16] = NUM_FATS
struct.pack_into('<H', boot, 17, ROOT_ENTRIES)
struct.pack_into('<H', boot, 19, TOTAL_SECS)
boot[21] = MEDIA_BYTE
struct.pack_into('<H', boot, 22, SECS_PER_FAT)
struct.pack_into('<H', boot, 24, SPT)
struct.pack_into('<H', boot, 26, HEADS)

# --- Boot code at 0x3E ---
# Loads SHELL.COM from data area to 0800:0100, one sector at a time.
# Uses DI for loop counter to avoid CX conflict with INT 13h CHS.
code = bytearray()

# Set up segments
code += bytes([0x31, 0xC0])          # XOR AX, AX
code += bytes([0x8E, 0xD8])          # MOV DS, AX
code += bytes([0xB8, 0x00, 0x08])    # MOV AX, 0x0800
code += bytes([0x8E, 0xC0])          # MOV ES, AX
code += bytes([0xBB, 0x00, 0x01])    # MOV BX, 0x0100

# DI = sector count, SI = current LBA
code += bytes([0xBF, shell_sectors & 0xFF, (shell_sectors >> 8) & 0xFF])  # MOV DI, count
code += bytes([0xBE, DATA_START_SEC & 0xFF, (DATA_START_SEC >> 8) & 0xFF])  # MOV SI, start

# read_loop:
read_loop_offset = len(code)

# Save BX (load pointer) and DI (counter)
code += bytes([0x53])                # PUSH BX
code += bytes([0x57])                # PUSH DI

# LBA to CHS: AX = SI
code += bytes([0x89, 0xF0])          # MOV AX, SI
code += bytes([0x31, 0xD2])          # XOR DX, DX
code += bytes([0xBB, SPT * HEADS, 0x00])  # MOV BX, SPT*HEADS
code += bytes([0xF7, 0xF3])          # DIV BX  -> AX=cyl, DX=rem
code += bytes([0x88, 0xC5])          # MOV CH, AL  (cylinder)
code += bytes([0x89, 0xD0])          # MOV AX, DX
code += bytes([0x31, 0xD2])          # XOR DX, DX
code += bytes([0xBB, SPT, 0x00])     # MOV BX, SPT
code += bytes([0xF7, 0xF3])          # DIV BX  -> AX=head, DX=sector
code += bytes([0x88, 0xC6])          # MOV DH, AL  (head)
code += bytes([0x88, 0xD1])          # MOV CL, DL
code += bytes([0xFE, 0xC1])          # INC CL  (1-based)

# Restore BX and DI (does NOT touch CX)
code += bytes([0x5F])                # POP DI
code += bytes([0x5B])                # POP BX

# INT 13h AH=02 read 1 sector
code += bytes([0xB8, 0x01, 0x02])    # MOV AX, 0x0201
code += bytes([0xB2, 0x00])          # MOV DL, 0 (drive A)
code += bytes([0xCD, 0x13])          # INT 13h
code += bytes([0x72])                # JC error
jc_offset = len(code)
code += bytes([0x00])                # placeholder

# Advance
code += bytes([0x81, 0xC3, 0x00, 0x02])  # ADD BX, 512
code += bytes([0x46])                     # INC SI
code += bytes([0x4F])                     # DEC DI
code += bytes([0x75])                     # JNZ read_loop
jnz_target = read_loop_offset - (len(code) + 1)
code += bytes([jnz_target & 0xFF])

# JMP FAR 0800:0100
code += bytes([0xEA, 0x00, 0x01, 0x00, 0x08])

# Error handler
error_offset = len(code)
code[jc_offset] = error_offset - (jc_offset + 1)

errmsg_fixup = len(code) + 1
code += bytes([0xBE, 0x00, 0x00])    # MOV SI, msg (fixup)
print_loop = len(code)
code += bytes([0xAC])                # LODSB
code += bytes([0x08, 0xC0])          # OR AL, AL
code += bytes([0x74, 0x04])          # JZ halt
code += bytes([0xB4, 0x0E])          # MOV AH, 0x0E
code += bytes([0xCD, 0x10])          # INT 10h
code += bytes([0xEB, 0xF5])          # JMP print_loop
code += bytes([0xF4])                # HLT
code += bytes([0xEB, 0xFD])          # JMP $-2

errmsg_offset = len(code)
code[errmsg_fixup] = (0x7C00 + 0x3E + errmsg_offset) & 0xFF
code[errmsg_fixup + 1] = ((0x7C00 + 0x3E + errmsg_offset) >> 8) & 0xFF
code += b'Disk error loading shell\r\n\x00'

print(f"  Boot code: {len(code)} bytes")
assert len(code) + 0x3E < 510, "Boot code too large!"

for i, b in enumerate(code):
    boot[0x3E + i] = b

boot[510] = 0x55
boot[511] = 0xAA
img[0:512] = boot

# --- FAT ---
fat = bytearray(SECS_PER_FAT * BYTES_PER_SEC)
fat[0] = MEDIA_BYTE
fat[1] = 0xFF
fat[2] = 0xFF


def fat12_set(cluster, value):
    """Write a FAT12 entry."""
    offset = cluster + cluster // 2
    val = struct.unpack_from('<H', fat, offset)[0]
    if cluster & 1:
        val = (val & 0x000F) | (value << 4)
    else:
        val = (val & 0xF000) | value
    struct.pack_into('<H', fat, offset, val)


# SHELL.COM cluster chain
for c in range(shell_clusters):
    cluster = c + 2
    fat12_set(cluster, cluster + 1 if c < shell_clusters - 1 else 0xFFF)

# Write FAT copies
fat_off1 = RESERVED_SECS * BYTES_PER_SEC
fat_off2 = (RESERVED_SECS + SECS_PER_FAT) * BYTES_PER_SEC
img[fat_off1:fat_off1 + len(fat)] = fat
img[fat_off2:fat_off2 + len(fat)] = fat

# --- Root directory ---
root_offset = ROOT_DIR_START_SEC * BYTES_PER_SEC


def fat_timestamp():
    """Return (fat_time, fat_date) words for current local time."""
    import datetime
    now = datetime.datetime.now()
    fat_time = ((now.hour << 11) | (now.minute << 5) | (now.second // 2))
    fat_date = (((now.year - 1980) << 9) | (now.month << 5) | now.day)
    return fat_time, fat_date


def make_dir_entry(name_83, start_cluster, file_size):
    """Create a 32-byte directory entry with current timestamp."""
    e = bytearray(32)
    parts = name_83.split('.')
    e[0:8] = parts[0].ljust(8).encode()[:8]
    e[8:11] = parts[1].ljust(3).encode()[:3] if len(parts) > 1 else b'   '
    e[11] = 0x20  # Archive
    ftime, fdate = fat_timestamp()
    struct.pack_into('<H', e, 22, ftime)   # Write time
    struct.pack_into('<H', e, 24, fdate)   # Write date
    struct.pack_into('<H', e, 26, start_cluster)
    struct.pack_into('<I', e, 28, file_size)
    return e


# SHELL.COM
img[root_offset:root_offset + 32] = make_dir_entry('SHELL.COM', 2, len(shell_data))

# SHELL.COM data
data_offset = DATA_START_SEC * BYTES_PER_SEC
img[data_offset:data_offset + len(shell_data)] = shell_data

# --- Add extra files ---
next_dir_entry = 1
next_cluster = 2 + shell_clusters

extra_files = ['TEST.COM', 'FREAD.COM', 'FWRITE.COM', 'SYSINFO.COM',
               'DIRTEST.COM', 'EXETEST.COM', 'TRACE21.COM', 'HDLTEST.COM',
               'DOSTEST.COM', 'CHILD.COM', 'HELLO.EXE', 'AUTOEXEC.BAT', 'README.TXT']

for fname in extra_files:
    fpath = os.path.join(TARGET_DIR, fname)
    if not os.path.exists(fpath):
        continue
    fdata = open(fpath, 'rb').read()
    if len(fdata) == 0:
        continue
    f_clusters = ((len(fdata) + BYTES_PER_SEC - 1) // BYTES_PER_SEC
                  + SECS_PER_CLUST - 1) // SECS_PER_CLUST

    # Check disk space
    end_sector = DATA_START_SEC + (next_cluster - 2 + f_clusters) * SECS_PER_CLUST
    if end_sector > TOTAL_SECS:
        print(f"  WARNING: {fname} won't fit, skipping")
        continue

    # Directory entry
    e = make_dir_entry(fname, next_cluster, len(fdata))
    eoff = root_offset + next_dir_entry * 32
    img[eoff:eoff + 32] = e

    # FAT chain
    for c in range(f_clusters):
        cl = next_cluster + c
        fat12_set(cl, cl + 1 if c < f_clusters - 1 else 0xFFF)

    # File data
    foff = (DATA_START_SEC + (next_cluster - 2) * SECS_PER_CLUST) * BYTES_PER_SEC
    img[foff:foff + len(fdata)] = fdata

    print(f"  {fname}: {len(fdata)} bytes, cluster {next_cluster} ({f_clusters} clusters)")
    next_dir_entry += 1
    next_cluster += f_clusters

# Re-write FAT with all chains
img[fat_off1:fat_off1 + len(fat)] = fat
img[fat_off2:fat_off2 + len(fat)] = fat

# --- Write image ---
img_file = os.path.join(TARGET_DIR, 'MEGADOS.IMG')
with open(img_file, 'wb') as f:
    f.write(img)

print(f"\nCreated {img_file}: {len(img)} bytes")

# Copy to HDOS
hdos_dest = os.path.join(HDOS_DIR, 'MEGADOS.IMG')
if os.path.isdir(HDOS_DIR):
    shutil.copy2(img_file, hdos_dest)
    print(f"Copied to {hdos_dest}")
else:
    print(f"HDOS dir not found: {HDOS_DIR}")

print("Done!")
