@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

echo ============================================
echo   Blog Auto Publish Script
echo ============================================
echo.

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Current directory is not a git repository.
    pause
    exit /b 1
)

set "HAS_CHANGES=0"
for /f "delims=" %%i in ('git status --porcelain') do (
    set "HAS_CHANGES=1"
    goto :changes_checked
)
:changes_checked

set "HAS_UNPUSHED=0"
git log origin/main..HEAD --oneline 2>nul | findstr . >nul
if not errorlevel 1 set "HAS_UNPUSHED=1"

if "%HAS_CHANGES%"=="0" if "%HAS_UNPUSHED%"=="0" (
    echo [INFO] No new changes to publish.
    pause
    exit /b 0
)

if "%HAS_CHANGES%"=="1" (
    echo [1/4] Building locally...
    call npm run build
    if errorlevel 1 (
        echo [ERROR] Build failed.
        pause
        exit /b 1
    )
    echo        Build OK
    echo.

    echo [2/4] Syncing dist to docs...
    powershell -NoProfile -Command ^
        "$ErrorActionPreference = 'Stop';" ^
        "if (-not (Test-Path 'docs')) { New-Item -ItemType Directory -Path 'docs' | Out-Null };" ^
        "Get-ChildItem -LiteralPath 'docs' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force;" ^
        "Copy-Item -Path 'dist\\*' -Destination 'docs' -Recurse -Force;" ^
        "New-Item -ItemType File -Path 'docs\\.nojekyll' -Force | Out-Null"
    if errorlevel 1 (
        echo [ERROR] Failed to sync dist to docs.
        pause
        exit /b 1
    )
    echo        Sync OK
    echo.

    echo [3/4] Committing...
    git add -A
    git diff --cached --quiet
    if errorlevel 1 (
        for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd HH:mm:ss'"`) do set "TIMESTAMP=%%i"
        git commit -m "publish: !TIMESTAMP!"
        if errorlevel 1 (
            echo [ERROR] Commit failed.
            pause
            exit /b 1
        )
        echo        Commit OK
        echo.
    ) else (
        echo        Nothing to commit
        echo.
    )
) else (
    echo [1/4] No local changes, only pushing existing commits...
    echo.
)

echo [4/4] Pushing to GitHub...
call :push_main
if errorlevel 1 (
    echo [ERROR] Push failed.
    echo Check your network or local proxy and run this script again.
    pause
    exit /b 1
)
echo        Push OK
echo.

echo ============================================
echo   Done! GitHub Pages will deploy shortly:
echo   https://shanz0ng.github.io/
echo ============================================
pause
exit /b 0

:push_main
git push origin main
if not errorlevel 1 exit /b 0

echo [WARN] Direct push failed. Retrying with proxy 127.0.0.1:7897...
git config http.proxy http://127.0.0.1:7897
git config https.proxy http://127.0.0.1:7897
git push origin main
set "PUSH_RESULT=%errorlevel%"
git config --unset http.proxy >nul 2>&1
git config --unset https.proxy >nul 2>&1
exit /b %PUSH_RESULT%
