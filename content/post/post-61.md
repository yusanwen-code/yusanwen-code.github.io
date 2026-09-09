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

## 每次对话都重新炼丹，太贵了

alchemy-furnace 里，每个分身（Agent）对话都要用它的合成 system prompt。这份 prompt 不是写死的，是炼出来的：跑一遍融合算子，先让 LLM 生成新的身份句，再让另一次 LLM 调用裁决冲突。也就是说，光"准备 prompt"这一步就是两次 LLM 调用，好几秒，几千 token。

而分身的人格在两次金丹更新之间是稳定的。每次对话都重算一遍，钱和延迟都花在重复劳动上。

那就加缓存。可缓存立刻带来那个经典难题：金丹会改，融合参数会调，算子会升级，缓存什么时候失效？失效太激进，等于没缓存；失效不及时，就出灵异 bug：我明明改了人设，Agent 还是老样子。

这篇讲我怎么处理这个矛盾。

## 让内容自己决定缓存

先说结论：失效判断不靠主动删除，靠内容寻址。

缓存的 value 是渲染好的合成 system prompt，外加工具定义和元数据。key 的主体是上一篇讲的 `lineage_hash`：它由父母金丹的 `content_hash`、算子名、算子版本、融合参数共同决定。任何一项变了，hash 就变，自然落到新 key 上，旧缓存根本没机会被错误命中。

key 长这样：

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

缓存放 Redis，TTL 设 7 天。但因为 key 随内容走，实际很少等到 TTL：内容不变就一直命中，内容一变就写新 key，旧 key 靠 TTL 自然回收，不用写任何删除逻辑。

这里有个前提，也是整个设计里我最满意的一步：金丹更新是 versioned 的，不是原地改。一个分身引用的是 `(elixir_id, version, content_hash)`，金丹作者改人设，生成的是新版本，分身的 lineage_hash 随之变化，下次对话自动触发重建。"原地更新导致缓存判断复杂"这类问题，从根上就不存在了。

![合成提示词缓存：lineage_hash 命中与重建链路](/images/post-61-prompt-cache.svg)

## 网关先查，引擎兜底

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

Python 引擎侧，`Synthesize` 内部也有一层针对子调用的 LLM 结果缓存（比如身份句生成），key 更细：

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

身份句的 temperature 压到了 0.4，比融合的 0.7 低一截。因为它是命名、概括类的任务，低温度结果更稳，缓存命中也更稳：同一对输入反复炼出同一句话，缓存才有意义。

## 踩到的坑

第一个是缓存击穿。热门分身的缓存恰好过期那一瞬，大量请求同时未命中，全打到 Python 引擎和 LLM 上。用 `singleflight`（Go 侧）加 Redis `SetNX` 做双保险：同一时刻、同一个 lineage_hash，只放一个请求真正去合成，其余等结果。这跟我在统一认证中心里做 JWT 刷新防雪崩是同一个套路。

第二个是算子升级。`OP_VERSION` 是缓存 key 的一部分，改了算子逻辑（换渲染模板、加字段）就必须递增版本号，否则旧 prompt 会被错误复用。我把它做成引擎启动时的常量，改了算子忘改版本，code review 一眼能看出来。也考虑过对算子代码本身算 hash，但那会让无关的注释改动也触发全量失效，权衡之后用了显式版本号。

第三个是金丹软删除。作者删了金丹，可分身还在引用它。我不做物理删除，只标记 `deleted_at`；加载时发现金丹被删，直接报"分身依赖的金丹已下架"，而不是拿残缺的金丹重新合成，那样产出的人格跟缓存里的完全对不上，用户只会觉得莫名其妙。

第四个是要不要预热。加了个简单策略：分身创建或更新后，网关异步发一个预热请求，把 prompt 先算好写进缓存，用户第一次对话就不卡顿。预热失败不阻塞主流程，对话时按需重建就是了。

第五个是演示模式。DEMO_MODE 下数据全在内存，缓存也退化成内存 map，进程重启就清空。听起来像 bug，其实是期望行为：演示环境本来就不需要持久化。

## 后来

回头看，这套缓存做的事情就一件：把"失效判断"从主动删除变成内容寻址。金丹版本化、算子版本化、参数入 hash，内容一变 key 就变，旧值自然淘汰；配合 singleflight 防击穿、低温度稳定子任务、异步预热，"每次对话都炼丹"就变成了"只有人格真正变化时才炼丹"。

对用户的体感差异很直接：分身对话的首 token 延迟，基本退化成一次普通 LLM 调用，而不是一次完整的融合流程。

> 封面图：[alexkerhead / Flickr](https://www.flickr.com/photos/26354629@N02/4012739993) · CC BY 2.0
