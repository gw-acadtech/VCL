@echo off
rem Licensed to the Apache Software Foundation (ASF) under one or more
rem contributor license agreements.  See the NOTICE file distributed with
rem this work for additional information regarding copyright ownership.
rem The ASF licenses this file to You under the Apache License, Version 2.0
rem (the "License"); you may not use this file except in compliance with
rem the License.  You may obtain a copy of the License at
rem
rem     http://www.apache.org/licenses/LICENSE-2.0
rem
rem Unless required by applicable law or agreed to in writing, software
rem distributed under the License is distributed on an "AS IS" BASIS,
rem WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
rem See the License for the specific language governing permissions and
rem limitations under the License.

rem DESCRIPTION:
rem

set /A STATUS=0

rem Get the name of this batch file and the directory it is running from
set SCRIPT_NAME=%~n0
set SCRIPT_FILENAME=%~nx0
set SCRIPT_DIR=%~dp0
rem Remove trailing slash from SCRIPT_DIR
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

set LOGS_DIR=%SCRIPT_DIR%\..\Logs\%SCRIPT_NAME%
if not exist %LOGS_DIR% mkdir %LOGS_DIR%

echo ======================================================================
echo %SCRIPT_FILENAME% beginning to run at: %DATE% %TIME%
echo Directory %SCRIPT_FILENAME% is running from: %SCRIPT_DIR%
echo.

echo ----------------------------------------------------------------------

echo %TIME%: Calling %SCRIPT_DIR%\debug_info.cmd...
echo *** %SCRIPT_FILENAME% start: *** >> %LOGS_DIR%\debug_info.log
start "debug_info.cmd" /WAIT cmd.exe /c "%SCRIPT_DIR%\debug_info.cmd >> %LOGS_DIR%\debug_info.log 2>&1"
echo.

echo ----------------------------------------------------------------------

echo %TIME%: Calling %SCRIPT_DIR%\configure_networking.vbs...
start "configure_networking.vbs" /MIN /WAIT cmd.exe /c "cscript.exe //NoLogo %SCRIPT_DIR%\configure_networking.vbs >> %LOGS_DIR%\configure_networking.log 2>&1"
echo ERRORLEVEL: %ERRORLEVEL%
set /A STATUS+=%ERRORLEVEL%
echo.

echo ----------------------------------------------------------------------

echo %TIME%: Calling %SCRIPT_DIR%\update_cygwin.cmd...
start "update_cygwin.cmd" /MIN /WAIT cmd.exe /c "%SCRIPT_DIR%\update_cygwin.cmd >> %LOGS_DIR%\update_cygwin.log 2>&1"
echo ERRORLEVEL: %ERRORLEVEL%
set /A STATUS+=%ERRORLEVEL%
echo.

echo ----------------------------------------------------------------------

echo %TIME%: Calling %SCRIPT_DIR%\debug_info.cmd...
echo *** %SCRIPT_FILENAME% end: *** >> %LOGS_DIR%\debug_info.log
start "debug_info.cmd" /WAIT cmd.exe /c "%SCRIPT_DIR%\debug_info.cmd >> %LOGS_DIR%\debug_info.log 2>&1"
echo.

echo ----------------------------------------------------------------------

echo %SCRIPT_FILENAME% finished at: %DATE% %TIME%
echo exiting with status: %STATUS%
"%SystemRoot%\system32\eventcreate.exe" /T INFORMATION /L APPLICATION /SO %SCRIPT_FILENAME% /ID 555 /D "exit status: %STATUS%" 2>&1
exit /B %STATUS%
