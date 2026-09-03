---
title: "合成提示词缓存：性格变化时的自动重建策略"
slug: "post-61"
date: 2026-03-31T10:30:00+08:00
draft: false
image: /images/post-61-cover.jpg
tags: ["缓存", "Prompt", "Agent"]
categories: ["AI"]
description: "给炼丹产物的合成 prompt 加缓存，并在金丹变更时自动失效重建"
---

## 问题背景

alchemy-furnace 里，一个分身（Agent）每次对话都要用它的合成 system prompt。如果每次对话都实时跑一遍融合算子 + LLM 合成，延迟和成本都不可接受——一次 crossover 要调一次 LLM 生成新身份句，再加一次 LLM 裁决冲突，单是"准备 prompt"就要好几秒、几千 token。而分身的人格在两次金丹更新之间是稳定的，根本没必要每次重算。

但缓存又有个经典难题：**金丹会改，融合参数会调，算子会升级，缓存什么时候失效？** 失效太激进等于没缓存，失效不及时会出现"我明明改了人设，Agent 还是老样子"的灵异 bug。这篇讲我怎么设计这个缓存。

## 方案/设计

缓存的 value 是渲染好的合成 system prompt（以及工具定义、元数据），key 必须能唯一决定"这份 prompt 是什么"。我用前一篇讲的 `lineage_hash` 作为缓存 key 的主体——它由父母金丹的 `content_hash`、算子名、算子版本、融合参数共同决定。只要其中任何一项变化，hash 就变，自然落到新 key，旧缓存不会被错误命中。

具体的 key 设计：

```
furnace:synth:{lineage_hash}
```

value 是一个 JSON：

```json
{
  "system_prompt": "渲染后的完整 prompt",
  "tools": ["mcp.search", "mcp.calc"],
  "lineage_hash": "9f8e...",
  "built_at": "2026-03-30T10:12:33+08:00",
  "op_version": "v2"
}
```

缓存放在 Redis，TTL 设 7 天，但因为 key 随内容变，实际不会等到 TTL——内容不变就一直命中，内容一变就写新 key。旧 key 靠 TTL 自然回收，不需要主动删除。

关键在于：**金丹更新是 versioned 的，不是原地改。** 一个分身引用的是 `(elixir_id, version, content_hash)`。金丹作者改了人设会生成新版本，分身的 `lineage_hash` 随之变化，下次对话就触发重建。这从根上避免了"原地更新导致缓存判断复杂"的问题。

## 关键代码

Go 网关在对话入口先查缓存，未命中才请求 Python 引擎：

```go
func (s *AgentService) BuildSystemPrompt(
    ctx context.Context, agent *Agent,
) (string, []string, error) {
    lineageHash := agent.LineageHash
    key := "furnace:synth:" + lineageHash

    // 1. 查 Redis
    if cached, err := s.rdb.Get(ctx, key).Result(); err == nil {
        var c PromptCache
        json.Unmarshal([]byte(cached), &c)
        metrics.CacheHit.Inc()
        return c.SystemPrompt, c.Tools, nil
    }

    // 2. 未命中，加载金丹，请求 Python 引擎合成
    elixirs, err := s.elixirRepo.LoadByAgent(ctx, agent.ID)
    if err != nil {
        return "", nil, err
    }
    result, err := s.furnaceCli.Synthesize(ctx, SynthesizeReq{
        Elixirs:  elixirs,
        Operator: agent.Operator,
        Params:   agent.FusionParams,
        OpVer:    OP_VERSION,
    })
    if err != nil {
        return "", nil, err
    }

    // 3. 写缓存（SetNX 防并发重复写）
    payload, _ := json.Marshal(PromptCache{
        SystemPrompt: result.SystemPrompt,
        Tools:        result.Tools,
        BuiltAt:      time.Now(),
    })
    s.rdb.SetNX(ctx, key, payload, 7*24*time.Hour)

    return result.SystemPrompt, result.Tools, nil
}
```

Python 引擎侧，`Synthesize` 内部也有一层 LLM 结果缓存（针对"身份句生成"这类子调用），用更细的 key：

```python
async def synthesize_identity(a: dict, b: dict) -> str:
    key = f"furnace:id:{a['content_hash']}:{b['content_hash']}:{OP_VERSION}"
    if cached := await redis.get(key):
        return cached

    prompt = IDENTITY_META_PROMPT.format(
        identity_a=a["identity"], identity_b=b["identity"],
        expertise_a=a["expertise"], expertise_b=b["expertise"],
    )
    result = await llm_client.complete(
        provider="deepseek",
        system=FURNACE_META_PROMPT,
        user=prompt,
        temperature=0.4,  # 身份句用低温度求稳定
    )
    await redis.set(key, result, ex=7*24*3600)
    return result
```

注意身份句用了更低的 temperature（0.4 vs 融合的 0.7），因为它是"命名/概括"类任务，低温度结果更稳，也更利于缓存命中。

## 踩坑/权衡

**缓存击穿**。某个热门分身的缓存恰好过期，瞬间大量请求都未命中，全打到 Python 引擎和 LLM。我用 `singleflight`（Go 侧）+ Redis `SetNX` 双保险：同一时刻同一个 lineage_hash 只有一个请求真正去合成，其余等结果。这跟我在统一认证中心里做 JWT 刷新防雪崩是同一个套路。

**算子升级要全量失效**。`OP_VERSION` 是缓存 key 的一部分，改了算子逻辑（比如调了渲染模板、加了字段）必须递增版本号，否则旧 prompt 会被错误复用。我把它做成引擎启动时的一个常量，改了算子忘改版本号，code review 时一眼能看出来。更稳的做法是对算子代码本身算 hash，但那会让无关的注释改动也导致全量失效，权衡后用显式版本号。

**金丹软删除的情况**。金丹作者删了金丹，但分身还引用它。我不做物理删除，只标记 `deleted_at`，加载时如果金丹被删，直接返回错误提示"分身依赖的金丹已下架"，而不是用一个残缺的金丹重新合成——那样产出的人格跟缓存里完全不同，会让用户困惑。

**要不要预热缓存**。我加了一个简单策略：分身创建/更新后，网关异步发一个预热请求把 prompt 算好写入缓存，用户第一次对话就不卡顿。但预热失败不阻塞主流程，对话时仍会按需重建。

**DEMO_MODE 下的缓存**。演示模式（下一篇讲）数据全在内存，缓存也用内存 map，进程重启就清空，这反而是期望行为——演示环境不需要持久化。

## 小结

合成提示词缓存的核心是把"失效判断"从主动删除变成"内容寻址"：用 lineage_hash 做 key，金丹版本化、算子版本化、参数入 hash，内容一变 key 就变，旧值自然淘汰。配合 singleflight 防击穿、低温度稳定子任务、异步预热，把"每次对话都炼丹"变成"只有人格真正变化时才炼丹"。这套缓存让分身对话的首 token 延迟基本退化为一次普通 LLM 调用，而不是一次完整的融合流程。

> 封面图：[alexkerhead / Flickr](https://www.flickr.com/photos/26354629@N02/4012739993) · CC BY 2.0
