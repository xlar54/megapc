@ECHO OFF
ECHO =========================
ECHO MegaDOS batch-feature test
ECHO =========================
ECHO args: [%0] [%1] [%2] [%3]

ECHO [GOTO forward]
GOTO LBL_A
ECHO   FAIL: reached dead code
:LBL_A
ECHO   PASS

ECHO [GOTO backward]
GOTO LBL_C
:LBL_B
ECHO   PASS
GOTO LBL_D
:LBL_C
GOTO LBL_B
:LBL_D

ECHO [IF EXIST]
IF EXIST TEST.COM ECHO   PASS: TEST.COM found
IF NOT EXIST NOSUCH.XYZ ECHO   PASS: NOSUCH.XYZ not found
IF EXIST NOSUCH.XYZ ECHO   FAIL: ghost file
IF NOT EXIST TEST.COM ECHO   FAIL: TEST.COM missing

ECHO [IF string]
IF foo==foo ECHO   PASS: foo eq foo
IF NOT foo==bar ECHO   PASS: NOT foo eq bar
IF foo==bar ECHO   FAIL: foo ne bar should skip
IF "a b"=="a b" ECHO   PASS: quoted eq

ECHO [IF ERRORLEVEL]
IF ERRORLEVEL 0 ECHO   PASS: level 0 or more
IF NOT ERRORLEVEL 1 ECHO   PASS: level below 1

ECHO [Env dump via SET]
SET
ECHO [Env set-then-expand]
SET MYVAR=hello_world
ECHO   MYVAR=[%MYVAR%]
ECHO [Env expansion]
ECHO   COMSPEC=[%COMSPEC%]
ECHO   PATH=[%PATH%]
ECHO   NONE=[%__NONE__%]

ECHO [Literal percent]
ECHO   100%% done

ECHO [CALL built-in]
CALL ECHO   PASS: CALL dispatched ECHO

ECHO [SHIFT]
ECHO   before: 1=[%1] 2=[%2] 3=[%3]
SHIFT
ECHO   after : 1=[%1] 2=[%2] 3=[%3]

ECHO =========================
ECHO done
ECHO =========================
