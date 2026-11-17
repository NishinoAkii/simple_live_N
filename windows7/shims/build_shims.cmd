@echo off
rem Build the Windows 7 shim DLLs (x64, no C runtime) into out\.
rem Run gen_shims.py first (writes gen\*.c, *.asm, *.def).
setlocal
set HERE=%~dp0
rem Visual Studio (any edition) with the C++ x64 tools, found with vswhere
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo Visual Studio with the C++ tools was not found& exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "%HERE%out" mkdir "%HERE%out"
if not exist "%HERE%obj" mkdir "%HERE%obj"
set CFLAGS=/nologo /c /O1 /GS- /Zl /W3 /utf-8 /D_WIN32_WINNT=0x0601
set LFLAGS=/nologo /DLL /NODEFAULTLIB /SUBSYSTEM:WINDOWS,6.01 /MANIFEST:NO /OPT:REF

for %%S in (k32w7 ws2w7 ntdw7) do (
  if exist "%HERE%gen\%%S.c" (
    cl %CFLAGS% /Fo"%HERE%obj\%%S.obj" "%HERE%gen\%%S.c" || exit /b 1
    ml64 /nologo /c /Fo"%HERE%obj\%%S_stubs.obj" "%HERE%gen\%%S_stubs.asm" || exit /b 1
    link %LFLAGS% /ENTRY:DllMain /DEF:"%HERE%gen\%%S.def" /OUT:"%HERE%out\%%S.dll" "%HERE%obj\%%S.obj" "%HERE%obj\%%S_stubs.obj" kernel32.lib ws2_32.lib || exit /b 1
  )
)

cl %CFLAGS% /Fo"%HERE%obj\path.obj" "%HERE%src\apiset_path.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_path.def" /OUT:"%HERE%out\api-ms-win-core-path-l1-1-0.dll" "%HERE%obj\path.obj" kernel32.lib || exit /b 1

cl %CFLAGS% /Fo"%HERE%obj\synch.obj" "%HERE%src\apiset_synch.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_synch.def" /OUT:"%HERE%out\api-ms-win-core-synch-l1-2-0.dll" "%HERE%obj\synch.obj" kernel32.lib || exit /b 1

cl %CFLAGS% /DSHIM_CORE /Fo"%HERE%obj\winrt_core.obj" "%HERE%src\apiset_winrt.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_winrt_core.def" /OUT:"%HERE%out\api-ms-win-core-winrt-l1-1-0.dll" "%HERE%obj\winrt_core.obj" kernel32.lib || exit /b 1
cl %CFLAGS% /DSHIM_STRING /Fo"%HERE%obj\winrt_string.obj" "%HERE%src\apiset_winrt.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_winrt_string.def" /OUT:"%HERE%out\api-ms-win-core-winrt-string-l1-1-0.dll" "%HERE%obj\winrt_string.obj" kernel32.lib || exit /b 1
cl %CFLAGS% /DSHIM_ERROR /Fo"%HERE%obj\winrt_error.obj" "%HERE%src\apiset_winrt.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_winrt_error.def" /OUT:"%HERE%out\api-ms-win-core-winrt-error-l1-1-0.dll" "%HERE%obj\winrt_error.obj" kernel32.lib || exit /b 1
cl %CFLAGS% /DSHIM_ERROR11 /Fo"%HERE%obj\winrt_error11.obj" "%HERE%src\apiset_winrt.c" || exit /b 1
link %LFLAGS% /NOENTRY /DEF:"%HERE%src\apiset_winrt_error11.def" /OUT:"%HERE%out\api-ms-win-core-winrt-error-l1-1-1.dll" "%HERE%obj\winrt_error11.obj" kernel32.lib || exit /b 1

echo shims built
