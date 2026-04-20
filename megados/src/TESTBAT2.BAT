@echo off
echo =========================
echo megados batch-feature test
echo =========================
echo args: [%0] [%1] [%2] [%3]

echo [goto forward]
goto lbl_a
echo   fail: reached dead code
:lbl_a
echo   pass

echo [goto backward]
goto lbl_c
:lbl_b
echo   pass
goto lbl_d
:lbl_c
goto lbl_b
:lbl_d

echo [if exist]
if exist command.com echo   pass: command.com found
if not exist nosuch.xyz echo   pass: nosuch.xyz not found
if exist nosuch.xyz echo   fail: ghost file
if not exist command.com echo   fail: command.com missing

echo [if string]
if foo==foo echo   pass: foo eq foo
if not foo==bar echo   pass: not foo eq bar
if foo==bar echo   fail: foo ne bar should skip
if "a b"=="a b" echo   pass: quoted eq

echo [if errorlevel]
if errorlevel 0 echo   pass: level 0 or more
if not errorlevel 1 echo   pass: level below 1

echo [env dump via set]
set
echo [env set-then-expand]
set myvar=hello_world
echo   myvar=[%myvar%]
echo [env expansion]
echo   comspec=[%comspec%]
echo   path=[%path%]
echo   none=[%__none__%]

echo [literal percent]
echo   100%% done

echo [call built-in]
call echo   pass: call dispatched echo

echo [shift]
echo   before: 1=[%1] 2=[%2] 3=[%3]
shift
echo   after : 1=[%1] 2=[%2] 3=[%3]

echo =========================
echo done
echo =========================
