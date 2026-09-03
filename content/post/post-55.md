---
title: "AI Vibe Coding 工作流：用 Claude Code 全栈交付"
slug: "post-55"
date: 2025-12-28T10:30:00+08:00
draft: false
image: /images/post-55-cover.jpg
tags: ["Claude Code", "Vibe Coding", "全栈"]
categories: ["AI编程"]
description: "一个人用 Claude Code 交付 Go+Python+Next.js 全栈项目的工作流"
---

## 问题背景

2026 年初我开源了 alchemy-furnace（炼丹炉），一个多人格融合 Agent 系统：Go(Gin+GORM) 做网关、Python(FastAPI) 做合成引擎、Next.js 做前端，三套技术栈一个人全栈交付。如果按传统写法，光是在不同语言和框架之间切换上下文就要花掉大量业余时间。我以 Claude Code 作为主力开发助手，慢慢形成了一套自己的"Vibe Coding"工作流。

## 工作流设计

第一步，先写 `CLAUDE.md`，把项目结构、技术栈、启动命令、代码规范和关键领域概念（金丹、丹炉、血统追溯）写清楚，作为 Agent 的长期记忆。第二步，复杂功能（Promptbreeder 变异算子、合成提示词缓存、多供应商适配）先用 Plan 模式让它出实施计划，我审完再让它写代码。第三步，小步提交，每个子任务一个 commit，便于 review 和回滚。第四步，测试先行，让 Claude 根据函数签名写 table-driven tests，我负责补边界 case。第五步，用 Task 跟踪多步任务，让它自己跑 `go build`、`go test`，失败了自己读报错再修。

## 关键配置

项目根的 `CLAUDE.md` 片段：

```markdown
# alchemy-furnace

## 架构
- gateway/ : Go 1.22, Gin + GORM, 负责 API Key 鉴权、路由、计费
- engine/  : Python 3.11, FastAPI, 多人格融合 + Promptbreeder 变异
- web/     : Next.js 14 App Router, Tailwind, shadcn/ui
- deploy/  : docker-compose, 单机部署

## 约定
- Go 代码通过 `make lint` 检查，禁止裸 ignore error
- Python 用 ruff + mypy，接口模型必须用 Pydantic
- 所有外部供应商调用走统一 provider 抽象
- API Key 入库前必须 AES-GCM 加密
- DEMO_MODE 下不调真实 LLM，返回内存 mock
```

`settings.json` 里放行高频命令，减少权限弹窗：

```json
{
  "permissions": {
    "allow": [
      "Bash(go build ./...)",
      "Bash(go test ./...)",
      "Bash(go vet ./...)",
      "Bash(ruff check *)",
      "Bash(pytest -q)",
      "Bash(docker compose config)"
    ]
  }
}
```

## 踩坑与权衡

第一，上下文是稀缺资源。我不会把整个仓库丢给 Claude，而是用子任务切给它："只看 `gateway/internal/provider` 目录，给 OpenAI 兼容层加一个 DeepSeek 适配"。大范围重构我会让它先列影响文件清单，再逐个改。第二，Vibe Coding 不等于不看代码。我会让它写完后跑测试，但 API Key 加密、变异算子的血统追溯这种关键路径，我自己逐行 review。AI 生成的代码能跑通不代表逻辑对，尤其涉及金额、权限、加密时。第三，幻觉 API 是真问题，比如它会编出不存在的 eino 函数签名。我的做法是让它先 `go doc` 或直接读 vendor 源码确认，而不是凭印象写。第四，多语言项目里在同一会话同时写 Go 和 Python 容易串味，我一般按服务分会话，或者明确说"接下来只写 Python，不要带入 Go 的错误处理风格"。第五，尽量用增量 Edit 而不是整体 Write，diff 清晰，也能及时发现它跑偏。

## 小结

Claude Code 让我这种以后端为主的人敢一个人扛前端和算法服务。它最擅长样板代码、测试用例、跨文件重构和根据报错自修复；我负责架构、边界和验收。alchemy-furnace 能在业余时间快速做到 46 star，这套工作流功不可没。

> 封面图：[recursion_see_recursion / Flickr](https://www.flickr.com/photos/39027808@N00/1423312308) · CC BY 2.0
