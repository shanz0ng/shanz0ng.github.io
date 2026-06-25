@echo off
cd /d "%~dp0"

echo ============================================
echo   Blog Publish Script
echo ============================================
echo.

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

echo [3/3] Pushing to GitHub...
git push origin main
if %errorlevel% neq 0 (
    echo [ERROR] Push failed. Check network.
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
