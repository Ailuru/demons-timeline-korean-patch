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

if not exist "%~dp0tools\release_installer\Install-KoreanPatch.ps1" (
    echo [PACKAGE_SCRIPT] 패치 실행 파일을 찾을 수 없습니다.
    echo ZIP 전체를 압축 해제하고 install.bat, restore.bat, DemonsTimeline_KoreanPatch 폴더를 함께 옮겨 주세요.
    if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
    exit /b 1
)
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [POWERSHELL_MISSING] Windows PowerShell을 찾을 수 없습니다. Windows 환경과 PATH 설정을 확인해 주세요.
    if not defined DEMONS_TIMELINE_INSTALLER_NO_PAUSE pause
    exit /b 1
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
