# 博客部署指南

## 当前部署方式：Netlify

**线上地址：** https://sparkly-chimera-57cc4a.netlify.app/

### 日常发布流程

写完文章后：

```bash
npm run build          # 构建
git add -A
git commit -m "xxx"    # 提交
git push origin main   # 推送
```

推送后 Netlify 自动检测到变更，自动执行 `npm run build` 并部署。全程约 1-2 分钟。

### Netlify 配置（一次性）

- **Build command:** `npm run build`
- **Publish directory:** `dist`
- **Branch:** `main`
- Netlify 账号：shanz0ng（GitHub 登录），Team: leungerlianger's team

---

## 为什么不用 GitHub Pages

GitHub Pages 底层依赖 GitHub Actions。2026 年 6 月 16 日之后，该 repo 的 Actions 引擎出现 `startup_failure`，所有 workflow（包括内置的 pages-build-deployment）全部无法执行。尝试过的方案：

| 方案 | 结果 |
|------|------|
| 经典 Pages (main + /docs) | startup_failure |
| 经典 Pages (main + /root) | startup_failure |
| GitHub Actions (deploy.yml) | startup_failure |
| API 触发 Pages build | 永远 building，不完成 |
| gh-pages 分支 | 构建卡住 |
| Disable/Enable Actions | 无效 |
| 删除全部 workflow 重来 | 无效 |
| 最简单的 echo hello workflow | startup_failure |

**结论：** GitHub Actions 对该 repo 完全不响应，是 GitHub 侧的 bug。

---

## 如果将来想切回 GitHub Pages

等 GitHub Actions 修复后，可以做以下任一方案：

### 方案 A：切回 main + /docs
```bash
npm run build
cp -r dist/* docs/
touch docs/.nojekyll
git add docs/
git commit -m "部署至 docs"
git push
```
然后在 Settings → Pages 选 main 分支 + /docs 目录。

### 方案 B：用 GitHub Actions
`.github/workflows/deploy.yml` 已写好，Settings → Pages Source 改 GitHub Actions 即可。
