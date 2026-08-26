---
title: "炼丹炉 alchemy-furnace：多人格融合 Agent 系统设计"
date: 2026-01-28T10:30:00+08:00
draft: false
tags: ["Agent", "开源", "alchemy-furnace"]
categories: ["开源"]
description: "把多个 Agent 人格像炼丹一样融合成一个新人格的系统设计"
---

## 问题背景

做知识库问答服务的时候我发现一个现象：用户并不满足于跟一个"通用助手"对话。他们想要一个既懂学术写作、又会写 Go、还带点毒舌风格的混合体。直接在 system prompt 里塞几段人设，效果很不稳定——不同人格的指令会互相打架，模型经常只"记住"最后一段。

我想要的是一个能把多个人格像炼丹一样"熔"在一起的系统：每个人格是结构化的、可复用的；融合过程是可追溯、可演化的；最终产物本身也是一个可独立调用的 Agent。这就是 alchemy-furnace（炼丹炉）的由来，开源在 `github.com/yusanwen-code/alchemy-furnace`。

## 方案/设计

整体分三层，我用"炼丹"做隐喻来命名领域对象：

- **金丹（Elixir）**：一个结构化技能包，封装一个人格的全部特质——身份、语气、专长、约束、示例对话、禁用词。它是融合的最小单位。
- **丹炉（Furnace）**：融合引擎，接收一组金丹，按策略生成一个新的合成人格。合成过程借鉴 Promptbreeder 的变异算子，支持 crossover、mutation、lineage 追溯。
- **金丹分身（Agent）**：融合产物，持有一个合成后的 system prompt 和一组工具定义，通过 OpenAI 兼容协议对外提供对话。

技术栈我做了明确切分：Go（Gin + GORM）做网关和业务编排，Python（FastAPI）做合成与 LLM 调用，Next.js 做前端。这样做的原因后面单独一篇讲。

数据模型上，金丹、融合任务、合成产物都是独立实体，融合任务记录 `parent_elixir_ids`、`mutation_operators`、`lineage_hash`，保证任何一个合成人格都能回溯到它的"祖先"。

关键入口（Go 网关侧）大致是这样：

```go
// FusionController 触发一次炼丹
type FusionController struct {
    fusionSvc FusionService
    furnaceCli FurnaceClient // Python 合成引擎
}

func (c *FusionController) Fuse(ctx *gin.Context) {
    var req FusionRequest
    if err := ctx.ShouldBindJSON(&req); err != nil {
        ctx.JSON(400, gin.H{"error": err.Error()})
        return
    }

    // 1. 加载金丹（技能包）
    elixirs, err := c.fusionSvc.LoadElixirs(ctx, req.ElixirIDs)
    if err != nil {
        ctx.JSON(404, gin.H{"error": "elixir not found"})
        return
    }

    // 2. 提交到 Python 丹炉
    job, err := c.furnaceCli.Submit(ctx, FurnaceJob{
        Elixirs:        elixirs,
        Strategy:       req.Strategy,        // crossover / mutate / ensemble
        Provider:       req.Provider,        // deepseek/qwen/zhipu/kimi/...
        Temperature:    req.Temperature,
        LineageParent:  req.ParentAgentID,
    })
    if err != nil {
        ctx.JSON(502, gin.H{"error": "furnace unreachable"})
        return
    }

    // 3. 异步落库，前端 SSE 订阅进度
    ctx.JSON(202, gin.H{"job_id": job.ID, "status": "queued"})
}
```

## 关键代码

Python 侧的合成引擎是核心。一个融合任务的骨架如下（FastAPI + 异步）：

```python
from fastapi import FastAPI, BackgroundTasks
from pydantic import BaseModel
import asyncio, uuid, hashlib

app = FastAPI()
_jobs: dict[str, "FusionJob"] = {}

class FurnaceJob(BaseModel):
    elixirs: list[dict]
    strategy: str
    provider: str
    temperature: float = 0.8
    lineage_parent: str | None = None

@app.post("/v1/furnace/fuse")
async def submit_fusion(job: FurnaceJob, bg: BackgroundTasks):
    job_id = str(uuid.uuid4())
    _jobs[job_id] = FusionJob(id=job_id, status="queued")
    bg.add_task(run_fusion, job_id, job)
    return {"job_id": job_id}

async def run_fusion(job_id: str, job: FurnaceJob):
    state = _jobs[job_id]
    try:
        state.status = "synthesizing"
        # 根据策略选择算子
        if job.strategy == "crossover":
            prompt = crossover_operator(job.elixirs)
        elif job.strategy == "mutate":
            prompt = mutate_operator(job.elixirs[0])
        else:
            prompt = ensemble_operator(job.elixirs)

        state.status = "calling_llm"
        synthesized = await llm_client.complete(
            provider=job.provider,
            system=FURNACE_META_PROMPT,
            user=prompt,
            temperature=job.temperature,
        )

        lineage = build_lineage(job.elixirs, job.strategy, synthesized)
        state.result = {"system_prompt": synthesized, "lineage": lineage}
        state.status = "done"
    except Exception as e:
        state.status = "failed"
        state.error = str(e)
```

这里的 `FURNACE_META_PROMPT` 是丹炉本身的元指令，它告诉 LLM："你不是在扮演任何一个人格，你是在把这些人格特质融合成一个新的、内在一致的人格。"这是整个系统里最关键的一段提示词——直接让模型"扮演混合体"会让它精神分裂，而让它以"人格设计师"的第三人称视角去合成，输出要稳定得多。

## 踩坑/权衡

第一个坑是**人格冲突**。一个金丹要求"回答必须简短"，另一个要求"给出完整推导"，crossover 之后模型会左右横跳。我的做法是在金丹结构里增加 `priority` 和 `conflicts_with` 字段，融合前先做一次冲突检测，硬冲突直接拒绝并提示用户，软冲突由 LLM 在合成阶段显式裁决并写入 `resolution_notes`。

第二个坑是**融合结果不可复现**。同一个组合跑两次出来的人格可能差别很大。我现在把 `temperature`、`provider`、`model_version`、算子版本、输入金丹的 `content_hash` 全部记录到 lineage 里，`lineage_hash = sha256(...)`。复现时用同样参数重跑，并支持把一次满意的结果"固化"为新的金丹，而不是每次重新融。

第三个权衡是**是否把合成逻辑放进 Go**。Go 调 LLM 完全可行，但 Promptbreeder 那一套算子迭代快、实验性强，Python 生态（pydantic、各类 prompt 工具、后续可能接 LangGraph）更顺手。所以我让 Go 做稳定的业务网关，Python 做易变的智能层，两边用内网 HTTP + 签名调用。

## 小结

alchemy-furnace 解决的核心问题是：**把"人设 prompt"从一段不可维护的文本，升级为可组合、可演化、可追溯的结构化资产**。金丹是模块，丹炉是算子，分身是产物，血统是账本。这套抽象跑通之后，后续的技能包复用、多金丹融合、缓存重建才有了地基。后面几篇我会分别展开三段式架构、技能包结构、变异算子、缓存和多供应商接入。
