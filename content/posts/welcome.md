---
title: "欢迎来到极客博客"
date: 2023-05-01T09:00:00+08:00
draft: false
tags: ["hugo", "博客", "极客"]
categories: ["技术"]
description: "第一篇示例文章，介绍这个极客风格博客"
---

## 关于这个博客

这是一个基于 **Hugo** + **PaperMod** 主题构建的极客风格静态博客。

### 特性

- ⚡ **极速构建** — Hugo 单二进制，毫秒级生成
- 🎨 **极客风格** — PaperMod 主题，深色模式原生支持
- 📝 **自定义时间** — 每篇文章的发布时间完全可控
- 🚀 **自动部署** — GitHub Actions 自动构建并发布到 GitHub Pages
- 💰 **零资费** — 完全免费，无服务器成本

### 自定义时间示例

这篇文章的发布时间是 `2023-05-01T09:00:00+08:00`，你可以在每篇文章的 Front Matter 中自由设置 `date` 字段，它可以是过去的任意时间，也可以是未来的时间。

```yaml
---
title: "文章标题"
date: 2020-01-01T00:00:00+08:00  # 自定义时间
draft: false
tags: ["tag1", "tag2"]
---
```

### 代码高亮

支持多种编程语言的语法高亮：

```python
def hello_geek():
    print("Hello, Geek World!")
    return 42

hello_geek()
```

```javascript
const geekBlog = {
    engine: 'Hugo',
    theme: 'PaperMod',
    hosting: 'GitHub Pages',
    cost: 0
};

console.log('极简、极速、极客');
```

> 开始写博客吧！
