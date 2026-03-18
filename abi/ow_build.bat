@echo off
setlocal

cd /d %~dp0\..
set ROOT=%CD%

set WATCOM=%ROOT%\.tools\openwatcom
set PATH=%WATCOM%\binnt64;%WATCOM%\binnt;%WATCOM%\binw;%PATH%
set EDPATH=%WATCOM%\eddat
set INCLUDE=%WATCOM%\h;%WATCOM%\h\nt

if exist abi\abi_proof.err del abi\abi_proof.err
if exist abi\abi_proof.obj del abi\abi_proof.obj
if exist abi\abi_proof.lst del abi\abi_proof.lst

wcc -q -bt=dos -ms -ecc -s -d1 -of+ -fo=abi\abi_proof.obj abi\abi_proof.c > abi\abi_proof.err 2>&1
if errorlevel 1 goto fail

wdis -s abi\abi_proof.obj > abi\abi_proof.lst 2>> abi\abi_proof.err
if errorlevel 1 goto fail

echo ABI proof build succeeded.
endlocal
exit /b 0

:fail
type abi\abi_proof.err
endlocal
exit /b 1