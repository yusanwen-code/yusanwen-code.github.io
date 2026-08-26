# Geek Blog — 极客风格静态博客

基于 Hugo + PaperMod 主题构建的零资费静态博客。

## 特性

- ⚡ **Hugo 极速构建** — 单二进制，毫秒级生成
- 🎨 **PaperMod 极客主题** — 深色模式、代码高亮、搜索、归档
- 📝 **完全自定义时间** — 每篇文章的 `date` 字段任意指定
- 🚀 **GitHub Actions 自动部署** — push 即部署，零手动操作
- 💰 **完全免费** — GitHub Pages 托管，无服务器成本
- 🔍 **站内搜索** — 基于 Fuse.js 的模糊搜索

## 项目结构

```
my-geek-blog/
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions 自动部署脚本
├── archetypes/             # 文章模板
├── content/
│   ├── posts/              # 博客文章
│   ├── archives.md         # 归档页面
│   ├── search.md           # 搜索页面
│   └── about.md            # 关于页面
├── static/                 # 静态资源（图片等）
├── themes/PaperMod/        # PaperMod 主题（子模块）
└── hugo.yml                # 站点配置
```

## 快速开始

### 1. 安装 Hugo

```bash
# macOS
brew install hugo

# Windows (Chocolatey)
choco install hugo-extended

# Linux (Debian/Ubuntu)
sudo apt install hugo

# 或者下载二进制文件
# https://github.com/gohugoio/hugo/releases
```

> **注意**：必须安装 Extended 版本，因为 PaperMod 主题使用了 Sass/SCSS。

### 2. 本地预览

```bash
cd my-geek-blog

# 启动开发服务器（包含草稿）
hugo server -D

# 访问 http://localhost:1313
```

### 3. 新建文章

```bash
# 使用 archetype 模板创建新文章
hugo new content posts/my-new-post.md
```

文章 Front Matter 示例：

```yaml
---
title: "文章标题"
date: 2024-01-15T10:00:00+08:00    # ← 完全自定义时间
draft: false
tags: ["tag1", "tag2"]
categories: ["分类"]
description: "文章描述"
---
```

### 4. 自定义时间

每篇文章的 `date` 字段可以设置为任意时间：

- **过去的时间**：`date: 2020-01-01T00:00:00+08:00`
- **未来的时间**：`date: 2025-12-31T23:59:59+08:00`
- **当前时间**：直接使用 `hugo new` 会自动使用当前时间

## 部署到 GitHub Pages

### 方式一：用户站点（推荐）

仓库名必须为 `yusanwen-code.github.io`，部署后访问 `https://yusanwen-code.github.io`。

### 方式二：项目站点

仓库名任意，部署后访问 `https://yusanwen-code.github.io/repo-name/`。

需要修改 `hugo.yml` 中的 `baseURL`：

```yaml
baseURL: 'https://yusanwen-code.github.io/repo-name'
```

### 部署步骤

1. **在 GitHub 创建仓库**
   - 用户站点：仓库名 = `yusanwen-code.github.io`
   - 项目站点：任意名称

2. **修改配置**
   编辑 `hugo.yml`，替换以下占位符：
   - `yusanwen-code.github.io` → 你的实际域名或 GitHub Pages URL
   - `yusanwen-code` → 你的 GitHub 用户名
   - `yusanwen-code@users.noreply.github.com` → 你的邮箱

3. **推送代码到 GitHub**

   ```bash
   # 初始化 Git（如果还没做）
   git init

   # 添加所有文件
   git add .

   # 提交
   git commit -m "Initial commit"

   # 关联远程仓库（替换为你的仓库地址）
   git remote add origin https://github.com/yusanwen-code/yusanwen-code.github.io.git

   # 推送到 main 分支
   git branch -M main
   git push -u origin main
   ```

4. **启用 GitHub Pages**
   - 进入仓库 → Settings → Pages
   - Source 选择 **Deploy from a branch**
   - Branch 选择 **gh-pages** /(root)
   - 点击 Save

5. **等待部署**
   - 进入 Actions 标签页查看部署进度
   - 大约 1-2 分钟后即可访问你的博客

### 自定义域名（可选）

1. 在 `static/` 目录下创建 `CNAME` 文件：
   ```
   blog.yourdomain.com
   ```

2. 在域名服务商添加 CNAME 记录：
   - 主机记录：`blog`
   - 记录值：`yusanwen-code.github.io`

3. 在 `hugo.yml` 中更新 `baseURL`：
   ```yaml
   baseURL: 'https://blog.yourdomain.com'
   ```

## 主题定制

### 修改主题颜色

编辑 `assets/css/extended/custom.css`（创建该文件）：

```css
:root {
  --primary: #ff6b6b;  /* 自定义主色调 */
}
```

### 添加自定义脚本

编辑 `layouts/partials/extend_head.html` 或 `extend_footer.html`。

### 更多配置

参考 [PaperMod 官方文档](https://github.com/adityatelange/hugo-PaperMod/wiki)。

## 常用命令

```bash
# 本地预览
hugo server -D

# 构建（输出到 public/ 目录）
hugo --minify

# 创建新文章
hugo new content posts/article-name.md

# 清理缓存
hugo --gc
```

## 技术栈

| 组件 | 说明 |
|------|------|
| Hugo | 静态站点生成器 |
| PaperMod | 极客风格主题 |
| GitHub Pages | 免费静态托管 |
| GitHub Actions | 自动 CI/CD |
| Fuse.js | 站内模糊搜索 |

## 许可证

MIT
