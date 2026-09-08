---
title: "炼丹炉 alchemy-furnace：多人格融合 Agent 系统设计"
slug: "post-57"
date: 2026-01-28T10:30:00+08:00
draft: false
image: /images/post-57-cover.jpg
tags: ["Agent", "开源", "alchemy-furnace"]
categories: ["开源"]
description: "把多个 Agent 人格像炼丹一样融合成一个新人格的系统设计"
---

## 在 system prompt 里堆人设，撑不住

做知识库问答服务的时候我发现一个现象：用户并不满足于跟一个"通用助手"对话，他们想要更具体的东西，比如一个既懂学术写作、又会写 Go、还带点毒舌的混合体。直接的思路是在 system prompt 里塞几段人设。我试过，效果很不稳定：不同人格的指令会互相打架，模型经常只"记住"最后一段。

我想要的是一个能把多个人格像炼丹一样"熔"在一起的系统：每个人格是结构化的、可复用的；融合过程可追溯、可演化；最终产物本身也是一个能独立调用的 Agent。alchemy-furnace（炼丹炉）就是干这个的，开源在 `github.com/yusanwen-code/alchemy-furnace`。

## 金丹、丹炉、分身

整体分三层，领域对象直接用炼丹的隐喻命名：

- 金丹（Elixir）：一个结构化技能包，封装一个人格的全部特质，身份、语气、专长、约束、示例对话、禁用词都在里面。它是融合的最小单位。
- 丹炉（Furnace）：融合引擎，接收一组金丹，按策略生成一个新的合成人格。合成过程借鉴 Promptbreeder 的变异算子，支持 crossover、mutation 和 lineage 追溯。
- 金丹分身（Agent）：融合产物，持有一份合成后的 system prompt 和一组工具定义，通过 OpenAI 兼容协议对外提供对话。

![金丹进炉，炼出新分身，血统全程落账](/images/post-57-furnace-flow.svg)

技术栈我做了明确切分：Go（Gin + GORM）做网关和业务编排，Python（FastAPI）做合成与 LLM 调用，Next.js 做前端。为什么这么切，后面单独一篇讲。

数据模型上，金丹、融合任务、合成产物是独立实体。融合任务会记下 `parent_elixir_ids`、`mutation_operators`、`lineage_hash`，任何一个合成人格都能回溯到它的"祖先"。

Go 网关侧的关键入口大致是这样：

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

## 元指令：让模型当设计师，不当演员

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

这里的 `FURNACE_META_PROMPT` 是丹炉本身的元指令，它告诉 LLM："你不是在扮演任何一个人格，你是在把这些人格特质融合成一个新的、内在一致的人格。"这段提示词是整个系统里最关键的一段。直接让模型"扮演混合体"，它会精神分裂；让它以人格设计师的第三人称视角去合成，输出要稳定得多。

## 三个坑

第一个坑是人格冲突。一个金丹要求"回答必须简短"，另一个要求"给出完整推导"，crossover 之后模型会左右横跳。后来我在金丹结构里加了 `priority` 和 `conflicts_with` 字段，融合前先做一次冲突检测：硬冲突直接拒绝并提示用户，软冲突交给 LLM 在合成阶段显式裁决，理由写进 `resolution_notes`。

第二个坑是融合结果不可复现。同一个组合跑两次，出来的人格可能差别很大。现在我把 `temperature`、`provider`、`model_version`、算子版本、输入金丹的 `content_hash` 全部记进 lineage，`lineage_hash = sha256(...)`。要复现就用同样参数重跑；碰到满意的结果，更好的办法是把它固化成新的金丹，而不是每次重新融。

第三个算权衡：要不要把合成逻辑放进 Go。Go 调 LLM 完全可行，但 Promptbreeder 那一套算子迭代快、实验性强，Python 生态（pydantic、各类 prompt 工具、后续可能接 LangGraph）更顺手。所以最后是 Go 做稳定的业务网关，Python 做易变的智能层，两边走内网 HTTP + 签名调用。

## 后来

回过头看，炼丹炉解决的核心问题是：**把"人设 prompt"从一段不可维护的文本，升级为可组合、可演化、可追溯的结构化资产**。这套抽象跑通之后，技能包复用、多金丹融合、缓存重建才有了落脚的地方。后面几篇我会分别展开三段式架构、技能包结构、变异算子、缓存和多供应商接入。
