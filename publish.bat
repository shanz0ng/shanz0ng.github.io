@echo off
cd /d "%~dp0"

:: Proxy for GitHub access
git config http.proxy http://127.0.0.1:7897
git config https.proxy http://127.0.0.1:7897

echo ============================================
echo   Blog Publish Script
echo ============================================
echo.

:: Try to push any unpushed commits first
set HAS_UNPUSHED=0
git log origin/main..HEAD --oneline 2>nul | find /c /v "" >nul
if %errorlevel% equ 0 (
    set HAS_UNPUSHED=1
) else (
    set HAS_UNPUSHED=0
)

if %HAS_UNPUSHED% equ 1 (
    echo [WARN] Unpushed commits found. Pushing now...
    git push origin main
    if not %errorlevel% equ 0 (
        echo [ERROR] Push failed. Check network and try again.
        pause
        exit /b 1
    )
    echo        Pushed OK
    echo.
)

:: Check for new changes to commit
git diff --quiet && git diff --cached --quiet
if %errorlevel% equ 0 (
    echo [INFO] No new changes to publish.
    pause
    exit /b 0
)

:: Build
echo [1/3] Building locally...
call npm run build
if not %errorlevel% equ 0 (
    echo [ERROR] Build failed.
    pause
    exit /b 1
)
echo        Build OK
echo.

:: Commit
echo [2/3] Committing...
set /p msg="Commit message (enter to use default): "
if "%msg%"=="" set msg=publish
git add -A
git commit -m "%msg%"
if not %errorlevel% equ 0 (
    echo [ERROR] Commit failed.
    pause
    exit /b 1
)
echo        Commit OK
echo.

:: Push
echo [3/3] Pushing to GitHub...
git push origin main
if not %errorlevel% equ 0 (
    echo [ERROR] Push failed.
    echo Commit saved locally. Run this script again to retry.
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
