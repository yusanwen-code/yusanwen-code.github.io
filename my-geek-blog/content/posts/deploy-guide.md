---
title: "Hugo 静态博客部署指南"
date: 2024-12-15T10:30:00+08:00
draft: false
tags: ["hugo", "github-pages", "部署"]
categories: ["教程"]
description: "详细说明如何将 Hugo 博客部署到 GitHub Pages"
---

## 部署到 GitHub Pages

### 前置要求

1. GitHub 账号
2. 安装 Git
3. 安装 Hugo（Extended 版本）

### 本地预览

```bash
# 进入博客目录
cd my-geek-blog

# 启动开发服务器
hugo server -D

# 访问 http://localhost:1313
```

### 部署步骤

1. **创建 GitHub 仓库**
   - 仓库名：`yourusername.github.io`（这是用户站点）
   - 或者任意名称（这是项目站点）

2. **推送代码**
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/yourusername/yourusername.github.io.git
   git push -u origin main
   ```

3. **配置 GitHub Pages**
   - 进入仓库 Settings → Pages
   - Source 选择 "Deploy from a branch"
   - Branch 选择 "gh-pages"
   - 保存

4. **等待部署**
   - GitHub Actions 会自动运行
   - 大约 1-2 分钟后即可访问

### 自定义域名（可选）

1. 在 `static/` 目录下创建 `CNAME` 文件
2. 文件内容为你的域名，如 `blog.yourdomain.com`
3. 在域名服务商添加 CNAME 记录指向 `yourusername.github.io`

---

> 你的博客已经 ready，去写作吧！
