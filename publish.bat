@echo off
cd /d "%~dp0"

:: Proxy for GitHub access
git config http.proxy http://127.0.0.1:7897
git config https.proxy http://127.0.0.1:7897

echo ============================================
echo   Blog Publish Script
echo ============================================
echo.

:: Check for unpushed commits first
git log origin/main..HEAD --oneline >nul 2>&1
if %errorlevel% equ 0 (
    for /f %%i in ('git log origin/main..HEAD --oneline ^| find /c /v ""') do set UNPUSHED=%%i
) else (
    set UNPUSHED=0
)
if %UNPUSHED% gtr 0 (
    echo [WARN] Found %UNPUSHED% unpushed commit(s). Trying to push first...
    git push origin main
    if %errorlevel% neq 0 (
        echo [ERROR] Push failed. Run this script again when network is ready.
        pause
        exit /b 1
    )
    echo        Previous commits pushed OK
    echo.
)

:: Check for new changes
git diff --quiet && git diff --cached --quiet
if %errorlevel% equ 0 (
    echo [INFO] No changes detected, nothing to publish.
    pause
    exit /b 0
)

echo [1/3] Building locally...
call npm run build
if %errorlevel% neq 0 (
    echo [ERROR] Build failed.
    pause
    exit /b 1
)
echo        Build OK
echo.

echo [2/3] Committing...
set /p msg="Commit message (enter to use default): "
if "%msg%"=="" set msg=publish
git add -A
git commit -m "%msg%"
if %errorlevel% neq 0 (
    echo [ERROR] Commit failed.
    pause
    exit /b 1
)
echo        Commit OK
echo.

:push_retry
echo [3/3] Pushing to GitHub...
git push origin main
if %errorlevel% neq 0 (
    echo [ERROR] Push failed.
    echo Commit is saved locally. When network recovers:
    echo   git push origin main
    echo Or just run this script again and it will push first.
    pause
    exit /b 1
)
echo        Push OK
echo.

echo ============================================
echo   Done! Netlify will deploy in 1-2 min:
echo   https://shanz0ng-blog.netlify.app/
echo ============================================
pause
