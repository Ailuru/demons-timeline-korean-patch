@echo off
setlocal
cd /d "%~dp0"
set "GAME_ROOT=%~dp0"
set "GAME_ROOT=%GAME_ROOT:~0,-1%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release_installer\Install-KoreanPatch.ps1" -Action Install -GameRoot "%GAME_ROOT%"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if "%INSTALL_EXIT%"=="0" (
    echo Korean patch installation completed.
) else (
    echo Installation failed. No unsupported game files were intentionally changed.
    echo Check the error message above and confirm that the game build is supported.
)

if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
exit /b %INSTALL_EXIT%
