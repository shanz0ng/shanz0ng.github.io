@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================
echo   博客发布脚本
echo ============================================
echo.

:: 检查是否有变更
git diff --quiet && git diff --cached --quiet
if %errorlevel% equ 0 (
    echo [提示] 没有检测到变更，无需发布。
    pause
    exit /b 0
)

:: 本地构建验证
echo [1/3] 本地构建验证...
call npm run build
if %errorlevel% neq 0 (
    echo [错误] 构建失败，请检查错误信息后重试。
    pause
    exit /b 1
)
echo       构建成功 ✓
echo.

:: 提交
echo [2/3] 提交变更...
set /p msg="输入提交信息 (直接回车使用默认): "
if "%msg%"=="" set msg=发布新文章
git add -A
git commit -m "%msg%"
if %errorlevel% neq 0 (
    echo [错误] 提交失败。
    pause
    exit /b 1
)
echo       提交成功 ✓
echo.

:: 推送
echo [3/3] 推送到 GitHub...
git push origin main
if %errorlevel% neq 0 (
    echo [错误] 推送失败，请检查网络后重试。
    pause
    exit /b 1
)
echo       推送成功 ✓
echo.

echo ============================================
echo   发布完成！
echo   Netlify 将自动部署，1-2 分钟后生效：
echo   https://sparkly-chimera-57cc4a.netlify.app/
echo ============================================
pause
