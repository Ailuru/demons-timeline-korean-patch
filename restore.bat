@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "GAME_ROOT=%~dp0"
set "GAME_ROOT=%GAME_ROOT:~0,-1%"

set "ANSWER="
set /p "ANSWER=검증된 원본 게임 파일로 복원하시겠습니까? [y/N]: "
if /I not "%ANSWER%"=="Y" (
    echo 복원을 취소했습니다.
    if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
    exit /b 0
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\release_installer\Install-KoreanPatch.ps1" -Action Restore -GameRoot "%GAME_ROOT%"
set "RESTORE_EXIT=%ERRORLEVEL%"

echo.
if not "%RESTORE_EXIT%"=="0" (
    echo 복원에 실패했습니다. 위 오류 메시지를 확인해 주세요.
    echo 롤백이 완료되지 않았다는 메시지가 있다면 안내된 복구 파일을 삭제하지 마세요.
)

if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
exit /b %RESTORE_EXIT%
