---
title: "Claude Code 的 Workflow 功能：6 任务分 4 波，多 Agent 并行开发三端功能"
slug: "post-73"
date: 2026-08-27T22:30:00+08:00
draft: false
image: /images/post-73-cover.jpg
tags: ["AI 全栈", "Agent", "工作流"]
categories: ["AI"]
description: "一个 141 行的 mjs 脚本，把 6 个开发任务、4 个波次、多个 AI Agent 编排起来，并行开发炼丹炉横跨三端的大功能。"
---

## 一个 141 行的脚本，指挥一群 AI 干活

炼丹炉（[Alchemy Furnace](https://github.com/yusanwen-code/alchemy-furnace)，我的开源项目）最近在做一个大功能：女娲蒸馏的范围收紧 + Skill 导出。它横跨三个端——Next.js 前端、Go 网关、Python 引擎——拆出来 6 个开发任务，有依赖、有先后、还要并行。

我用的方案是 **Claude Code 的 Workflow 功能**：写一个 141 行的 mjs 脚本，把 6 个任务分成 4 个波次，每波派多个 AI Agent 并行干活。脚本开头长这样：

```js
export const meta = {
  name: 'nuwa-scope-skill-export',
  description: '按计划实现女娲炼丹范围收紧 + Skill 导出（6 Task 分波并行）',
  phases: [
    { title: 'Wave A: 并行底座', detail: 'Task1 前端入口 + Task2 Python 链路 + Task3 Skill 渲染器' },
    { title: 'Wave B: 服务端接合', detail: 'Task2b Go/前端错误透传 + Task4 导出接口' },
    { title: 'Wave C: 前端导出 UI', detail: 'Task5 详情导出对话框' },
    { title: 'Wave D: 端到端验收', detail: 'Task6 全量回归与修复' },
  ],
}
```

Workflow 的编排原语就几个：`agent()` 派一个 Agent 做一件事，`parallel()` 并行跑一组，`pipeline()` 流水线，`phase()` 分阶段。流程是确定性的（脚本写死的），干活是并行的（agent 同时跑）——**确定性编排 + 并行吞吐**，这就是 Workflow 和"让 AI 自由发挥"最大的区别。

## 分波设计：依赖关系决定顺序

6 个任务不是一把梭全并行——它们之间有依赖。分波的核心原则：**同一波内的任务互不依赖且文件隔离，波与波之间靠产物衔接**。

![Claude Code Workflow：6 Task × 4 波次并行编排](/images/post-73-waves.svg)

Wave A 三个任务互不依赖：前端改入口、Python 改链路、Python 写渲染器，改动文件完全不重叠，并行跑。Wave B 接合服务端：错误透传要读 Task2 的产物（Python 结构化错误），导出接口要调 Task3 的渲染器——等 A 波完成再动。C、D 依此类推。

## 多 Agent 协调的六个细节

分波只是骨架，真正让 6 个 Agent 不打架的是这些细节：

**1. COMMON 纪律注入。** 每个 Agent 的 prompt 都是 `COMMON + TASK + 终止条件` 三段拼起来的。COMMON 里写死硬约束：TDD 先红后绿、只改自己任务列出的文件、提交格式 `type(scope): 中文描述`、**绝不 `git add -A`**、绝不提交 docs/superpowers/ 和 specs/ 等元文档、i18n 必须中英双语、测试命令、凭据保密。纪律写进 prompt 而不是靠自觉，6 个 Agent 才不会互相污染。

**2. 文件隔离 + 以磁盘为准。** 每个任务只允许碰自己的文件，但并发任务可能改到同一文件——所以约束里有一条："编辑前先 Read 磁盘最新内容，不要基于记忆"。并行和踩脚之间的平衡，靠这条纪律兜底。

**3. 依赖确认靠 git log。** Wave B/C 的任务 prompt 里写着："先 git log 确认依赖任务已完成，并读它的接口签名再动手"。Agent 之间不通信，通过提交记录对齐。

**4. 终止条件。** 每个任务都附一段 A3：文件不存在或结构差异巨大、关键依赖无法确认、测试连续 3 次修复失败——**立即停止并报告，不许硬撑**。这防止 Agent 在不确定的情况下编造"成功"。

**5. TDD 是硬约束。** 每个任务第一步都是"写失败测试 → 跑红 → 最小实现 → 跑绿"。6 个 Agent 并行写代码，质量一致性靠测试框架兜底。

**6. 进度可视化。** 每波完成打一条 `log()`：`task1=ok task2=FAILED`，失败的任务肉眼可见，可以在下一波前人工干预。

## 三端是怎么被协调的

这个功能本身横跨三端，Workflow 的波次刚好和端的分工对齐：

| 端 | 技术栈 | 对应的任务 |
|---|---|---|
| 前端 | Next.js | Task1 收紧女娲入口、Task5 导出对话框 |
| Go 网关 | Gin + GORM | Task2b 错误透传、Task4 导出接口 |
| Python 引擎 | FastAPI | Task2 蒸馏链路、Task3 Skill 渲染器 |

有意思的是 Python 端同时有 Task2 和 Task3 两个并行 Agent——它们文件不同（链路 vs 渲染器）所以不冲突，但同端并行也要求 prompt 里把边界写得特别清楚："不要碰 backend/go/ 与 frontend/ 的 UI 文件——那些由另一任务负责"。

## 复盘：Workflow 教给我的

- **复杂功能 = 拆波并行，依赖决定顺序。** 先画出任务依赖图，互不依赖的并行，有依赖的排波次。比"一个 Agent 从头做到尾"快得多，比"全并行"稳得多。
- **纪律要写进 prompt，不是靠提醒。** 提交纪律、文件边界、TDD、终止条件，每一条都防止一种 Agent 翻车方式。
- **终止条件比任务本身重要。** 允许 Agent 说"我卡住了"，比让它硬编一个成功报告安全一个量级。
- **上下文隔离是并行的前提。** 每个 Agent 只拿自己的任务片段，看不到其他任务的 prompt——专注 + 不越界。

这个脚本不是银弹：它适合任务边界清晰、文件可隔离、有测试兜底的场景。如果任务互相纠缠，先拆任务再谈并行。项目、计划文档和完整脚本都在 [GitHub](https://github.com/yusanwen-code/alchemy-furnace) 上，Wave A 的并行底座写法可以直接抄。

> 封面图：[richard_clyborne / Flickr](https://www.flickr.com/photos/richard_clyborne/32874464137) · CC BY 2.0
