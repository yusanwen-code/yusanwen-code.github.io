---
title: "多模型路由设计：按成本、能力与延迟选择模型"
slug: "post-39"
date: 2025-04-22T10:30:00+08:00
draft: false
tags: ["模型路由", "LLM", "成本优化"]
categories: ["AI"]
description: "知识库问答服务统一适配层之上的模型选择与降级策略"
---

## 问题背景

知识库问答服务要同时对接 OpenAI、Azure OpenAI、VLLM 自建、HuggingFace 以及多家国产模型（DeepSeek、通义、智谱、Kimi、百川、文心）。不同场景对模型的要求不一样：闲聊类要便宜快速，复杂推理要强模型，embedding 和 rerank 又有专门的模型。如果让调用方自己指定模型，很容易出现"简单问题调了最贵的模型"或"某个供应商挂了整个服务不可用"。

我们在统一 LLM 适配层之上加了一层模型路由，按能力、成本、延迟和可用性自动选择。

## 方案设计

核心是一个 `Router` 接口和一组基于策略的实现。配置中为每个模型打标签：

```yaml
models:
  - name: deepseek-chat
    provider: deepseek
    capabilities: [chat, tool_call]
    cost_per_1k: 0.001
    max_tokens: 8192
    priority: 3
  - name: gpt-4o
    provider: azure
    capabilities: [chat, tool_call, vision]
    cost_per_1k: 0.02
    max_tokens: 16384
    priority: 1
  - name: qwen-long
    provider: dashscope
    capabilities: [chat, long_context]
    cost_per_1k: 0.0005
    max_tokens: 1000000
    priority: 2
```

路由入口接收一个 `RouteRequest`，描述本次调用需要的能力和预算约束：

```go
type RouteRequest struct {
    Capabilities []string // chat / tool_call / vision / long_context
    MaxCost      float64  // 单次最大成本（美元/千token），0 表示不限
    PreferFast   bool
    TenantID     string
}

type Router interface {
    Select(ctx context.Context, req RouteRequest) (*ModelEndpoint, error)
}
```

默认实现按"能力过滤 → 优先级排序 → 成本约束 → 健康检查"四步筛选：

```go
func (r *DefaultRouter) Select(ctx context.Context, req RouteRequest) (*ModelEndpoint, error) {
    candidates := r.registry.Filter(func(m *ModelEndpoint) bool {
        return hasAllCaps(m.Capabilities, req.Capabilities)
    })
    if req.MaxCost > 0 {
        candidates = filterCost(candidates, req.MaxCost)
    }
    sort.SliceStable(candidates, func(i, j int) bool {
        if req.PreferFast {
            return candidates[i].P95Latency < candidates[j].P95Latency
        }
        return candidates[i].Priority < candidates[j].Priority
    })
    for _, m := range candidates {
        if r.breaker.Available(m.Name) {
            return m, nil
        }
    }
    return nil, ErrNoHealthyModel
}
```

适配层拿到 endpoint 后，用统一的 `Client` 接口发起调用，各家 provider 的差异在 provider 实现内消化：

```go
type Client interface {
    Chat(ctx context.Context, req *ChatRequest) (*ChatResponse, error)
    Stream(ctx context.Context, req *ChatRequest) (<-chan *ChatChunk, error)
    Embed(ctx context.Context, req *EmbedRequest) (*EmbedResponse, error)
}
```

## 踩坑与权衡

**能力标签要粗粒度**。一开始我们把"支持 JSON mode""支持并行 tool call"也做成标签，结果组合爆炸，路由经常选不出模型。后来只保留 chat、tool_call、vision、long_context 四个硬能力，细粒度差异在 prompt 层和适配层处理。

**熔断器是必须的**。某家供应商偶发 5xx 或超时时，如果所有流量都打过去会雪崩。我们对每个 endpoint 维护一个简单的滑动窗口熔断器：连续 N 次失败或错误率超阈值就打开 30 秒，期间跳过该模型。熔断器状态配合路由，实现了自动降级。

**成本与效果不能只看单价**。便宜模型如果需要更多轮重试或答非所问，综合成本反而更高。我们把"模型平均消耗 token 数 × 单价"作为实际成本指标，而不是只看单价。部分租户可以配置"质量优先"，路由直接跳到 priority 最高的模型。

**长上下文单独路由**。普通模型有上下文长度限制，超长文档问答不能简单截断。路由检测到输入 token 接近阈值时，自动切到带 long_context 能力的模型（如 qwen-long），这部分逻辑对调用方透明。

**流式与非流式共用路由**。SSE 流式输出对首 token 延迟敏感，PreferFast 场景下我们倾向选 P95 更低的模型，即使单价略高，因为用户体验差异明显。

## 小结

多模型路由把"选模型"这件事从业务代码里抽离出来。知识库问答服务里业务方只描述"我需要什么能力、预算多少"，路由决定具体走哪家、哪个模型，并在异常时自动降级。统一适配层加路由，让我们能平滑地接入新模型、在供应商之间切换，也把整体推理成本控制在可预期范围内。
