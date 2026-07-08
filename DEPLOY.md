# 博客部署指南

## 当前部署方式：Cloudflare Pages

本项目是 Astro 静态站点，Cloudflare Pages 直接从 GitHub 源码仓库拉取并构建，不再依赖 GitHub Pages，也不需要同步 `docs/`。

## Cloudflare Pages 配置

在 Cloudflare Pages 创建项目时使用：

- Framework preset: `Astro`
- Build command: `npm run build`
- Build output directory: `dist`
- Root directory: `/`
- Production branch: `main`

## 必配环境变量

在 Cloudflare Pages 的 `Settings -> Environment variables` 里设置：

- `SITE_URL`

值填写你的最终站点地址，例如：

- `https://your-project.pages.dev`
- `https://blog.example.com`

`src/config.ts` 会优先读取这个变量，用它生成 canonical、sitemap 和 RSS 链接。

## 日常发布流程

写完文章后直接双击 `publish.bat`，脚本会自动：

1. 本地构建
2. 提交源码
3. 推送到 GitHub

推送到 `main` 后，Cloudflare Pages 会自动拉取最新提交并部署。

## 自定义域名

后续如果要绑定自己的域名，在 Cloudflare Pages 后台添加域名后，把 `SITE_URL` 改成最终域名即可。

## 本地注意事项

- 不要把 GitHub Token 写进 `git remote` URL
- 如果网络受限，可以给 Git 配置代理：`http://127.0.0.1:7897`
- `docs/` 和仓库根目录里的静态文件是历史遗留，不再作为正式发布源
