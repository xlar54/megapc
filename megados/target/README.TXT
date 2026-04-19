MegaDOS
A free, open source MS-DOS compatible operating system
for the Mega65 Personal Computer.

Find my repo at https://github.com/xlar54/megapc

Shell Commands:
  DIR [/W] [/A] - List files        MKDIR  - Create directory
  TYPE          - Display file       RMDIR  - Remove directory
  COPY          - Copy file          CD     - Change directory
  DEL           - Delete file        SET    - Environment variables
  REN           - Rename file        PROMPT - Set prompt format
  CLS           - Clear screen       DATE   - Show current date
  VER           - Show version       TIME   - Show current time
  ECHO          - Print text         REM    - Comment (batch)
  PAUSE         - Wait for key       PATH   - Set search path
  A: / B:       - Switch drive

External Commands:
  FORMAT drive: [/S] [/V:label] [/Q] - Format a floppy disk
  CHKDSK [drive:] [/F]               - Check disk for errors
  SYS drive:                         - Transfer system files
  LABEL [drive:] [label]             - Set volume label
  ATTRIB [+/-RHSA] file              - Change file attributes
  FIND [/I] [/C] [/N] [/V] "str" file - Search text in files
  EDLIN file                         - Line editor
  MEM                                - Display memory usage
  DOSKEY                             - Command history (TSR)
  MORE < file                        - Page output

Supports .COM and .EXE programs, batch files (.BAT),
I/O redirection (> >> <), subdirectories, PATH search,
CONFIG.SYS device drivers, and 20 file handles.

Disk formats: 360K, 720K, 1.2MB, 1.44MB (auto-detected).
