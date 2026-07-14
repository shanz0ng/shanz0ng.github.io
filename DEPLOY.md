# 博客部署指南

## 当前目标：GitHub Pages

本项目是 Astro 静态博客。现在重新尝试使用 GitHub Pages 部署。

推荐 GitHub Pages 设置：

- Source: `Deploy from a branch`
- Branch: `main`
- Folder: `/docs`

仓库也包含 `.github/workflows/deploy.yml`，如果 GitHub Pages 的 Source 改成 `GitHub Actions`，该 workflow 会直接构建 `dist` 并部署。

## 日常发布

写完文章后双击 `publish.bat`。脚本会：

1. 本地执行 `npm run build`
2. 把 `dist/` 同步到 `docs/`
3. 提交源码和 `docs/` 构建产物
4. 推送到 GitHub

推送后 GitHub Pages 会从 `main / docs` 发布站点。

## 站点地址

- https://shanz0ng.github.io/

## 注意事项

- 文章源码放在 `src/content/blog/`
- 不要手动编辑 `docs/`，它是构建产物
- 如果 GitHub 直连失败，`publish.bat` 会自动尝试 `http://127.0.0.1:7897` 代理
