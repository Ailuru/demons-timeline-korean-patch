@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "GAME_ROOT=%~dp0"
set "GAME_ROOT=%GAME_ROOT:~0,-1%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release_installer\Install-KoreanPatch.ps1" -Action Install -GameRoot "%GAME_ROOT%"
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
if not "%INSTALL_EXIT%"=="0" (
    echo 설치에 실패했습니다. 위 오류 메시지를 확인해 주세요.
    echo 롤백이 완료되지 않았다는 메시지가 있다면 안내된 복구 파일을 삭제하지 마세요.
)

if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
exit /b %INSTALL_EXIT%
