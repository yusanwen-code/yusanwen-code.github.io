---
title: "独立完成前端页面：Vibe Coding 下的全栈闭环"
slug: "post-66"
date: 2026-06-18T10:30:00+08:00
draft: false
image: /images/post-66-cover.jpg
tags: ["Vibe Coding","前端","全栈"]
categories: ["AI编程"]
description: "后端工程师用 Claude Code 和 Cursor 独立交付前端页面的真实体验。"
---

## 排期等两周，不如自己上

我是后端出身，Go 和 Python 写得顺手，前端一直停留在"能改 Vue 模板、写点 jQuery"的水平。

alchemy-furnace 立项时，我想做一个多人格融合 Agent 的演示平台，需要一个能配置技能包、展示融合血统、对比生成结果的界面。前端同学的排期要等两周，我决定自己上，用 Claude Code 和 Cursor 做 Vibe Coding。

三周后，我一个人交付了 Go 网关 + Python 合成引擎 + Next.js 前端的完整 DEMO，前端包括技能包编辑器、融合过程可视化、多模型结果对比三个主页面。

## 分三步走，不让 AI 一把梭

第一步，先把后端契约定死。用 Go（Gin + GORM）把 API 写好，Swagger 文档直接生成。前端只需要对着文档调接口，不让 AI 猜后端长什么样。这是后端工程师做全栈的最大优势：你能自己定义契约。

```go
// alchemy-furnace 网关侧的技能包接口
r.POST("/api/skills", func(c *gin.Context) {
    var req CreateSkillReq
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(400, gin.H{"error": err.Error()})
        return
    }
    skill, err := skillSvc.Create(c.Request.Context(), &req)
    if err != nil {
        c.JSON(500, gin.H{"error": err.Error()})
        return
    }
    c.JSON(200, skill)
})
```

第二步，用 Cursor 的 Composer 搭骨架。我描述需求："用 Next.js App Router + shadcn/ui + Tailwind，做一个三栏布局，左侧技能包列表，中间编辑器，右侧预览"，它生成初始代码后我再逐块调整。这里的关键是给足上下文：把 Swagger 文档、设计参考截图、已有的组件目录一起喂给它。

第三步，复杂交互用 Claude Code 细抠。比如融合血统的树形可视化（Promptbreeder 变异算子 + 血统追溯），我在 Claude Code 里打开相关组件，直接说"这里要改成 DAG 布局，节点颜色按代数区分，点击节点展示该代的 Prompt 全文"，它会读现有代码再精准改。

![Vibe Coding 全栈闭环：定契约、搭骨架、细抠交互，外加一条截图回修的反馈回路](/images/post-66-vibe-fullstack.svg)

## 五个教训

第一，别指望 AI 生成的样式一次到位。布局错乱、响应式断点不对、暗色模式漏色，它经常顾头不顾尾。我的办法是每生成一块就在浏览器里看，不对就截图丢回去让它修。小步快跑，别攒到最后。

第二，状态管理别过度设计。AI 一上来就喜欢套 Zustand/Redux，其实大部分页面用 React Query 管服务端状态、`useState` 管本地状态就够了。alchemy-furnace 这种 DEMO 规模，最后我什么全局状态库都没引入。

第三，类型安全一定要守住。TypeScript strict 模式全开，API 响应类型从 OpenAPI 生成（`openapi-typescript`），不让 AI 随手写 `any`。后端改字段，前端编译就能发现，比联调时互相甩锅高效太多。

第四，UI 库选 shadcn/ui 这类可复制的。组件源码直接进你的仓库，想怎么改都行，比黑盒组件库适合 Vibe Coding。AI 对它的代码也最熟，生成质量明显更高。

第五，后端思维得切换。后端是"请求-响应"，前端是"渲染是状态的函数"。一开始我总在 `useEffect` 里绕圈子，后来想明白这一点，写起来就顺了。该花半天过一遍 React 官方文档，比让 AI 反复擦屁股强。

## 后来

Vibe Coding 没有把前端变成"不需要学"，只是把门槛从"记住所有 API"降到了"理解核心概念 + 会描述需求 + 能判断对错"。

后端工程师独立交付前端的最大红利，是契约和实现都能自己掌控，联调成本归零。alchemy-furnace 上线后我反而觉得，至少在产品快速迭代期，这种全栈闭环比前后端分工还快。

> 封面图：[juhansonin / Flickr](https://www.flickr.com/photos/38869431@N00/9791626204) · CC BY 2.0
