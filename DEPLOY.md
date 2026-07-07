# 博客部署指南

## 当前部署方式：GitHub Pages

**线上地址：** https://shanz0ng.github.io/

本项目是 Astro 静态站点，构建产物输出到 `dist/`。GitHub Pages 通过 GitHub Actions 自动构建并部署，不需要 `docs/` 目录，也不需要额外保留 Netlify 配置。

### 日常发布流程

写完文章后：

```bash
npm run build
git add -A
git commit -m "xxx"
git push origin main
```

推送到 `main` 后，GitHub Actions 会自动执行构建并发布到 GitHub Pages。

## 仓库内的部署配置

- 工作流文件：`.github/workflows/deploy.yml`
- 构建命令：`npm run build`
- 发布目录：`dist`
- 站点地址配置：`src/config.ts` 中的 `SITE.website`

## 首次启用时需要检查

在 GitHub 仓库页面确认以下设置：

1. `Settings -> Pages`
2. `Source` 选择 `GitHub Actions`
3. 仓库名称保持为 `shanz0ng.github.io`

这个仓库是用户主页仓库，所以站点根路径就是 `/`，当前 Astro 配置不需要额外设置 `base`。

## 本地注意事项

- 不要把 GitHub Token 写进 `git remote` URL
- 如果网络受限，可以给 Git 配置代理：`http://127.0.0.1:7897`
- `.netlify/` 只是旧部署残留，本项目现在不再依赖它
