---
title: "多轮对话上下文管理：滑动窗口与 Token 预算控制"
slug: "post-32"
date: 2025-01-02T10:30:00+08:00
draft: false
tags: ["对话","上下文","Token"]
categories: ["AI"]
description: "在 Token 限制内管理多轮对话历史的方案"
---

## 问题背景

知识库问答服务上线后，多轮对话是最常用的功能。用户连续聊二三十轮很常见，但每个模型都有上下文窗口限制（比如 4K、32K、128K）。如果不做控制，历史消息会撑爆 Token 上限，直接报 400 错误；如果简单截断最新的几条，又会丢失关键上下文，让模型"失忆"。

我们需要一套上下文管理机制，在有限的 Token 预算内，尽可能保留对话的关键信息，同时支持不同模型的窗口大小。

## 方案设计

采用三层策略，按优先级递进：

1. **滑动窗口**：保留最近 N 轮对话（一轮 = 一条 user + 一条 assistant），默认 10 轮。这是最简单也最有效的策略，大多数对话的关键信息集中在近期。
2. **Token 预算裁剪**：窗口内的消息按 Token 数估算（用 tiktoken 或近似算法），如果超出预算，从最旧的消息开始丢弃，直到总 Token 数（含系统提示和检索结果）在限制内。
3. **历史摘要**：对于被裁剪掉的早期对话，异步调用小模型生成摘要，作为一条 system 消息注入，保留对话的主线脉络。

另外，系统提示词和 RAG 检索到的上下文优先级最高，它们的 Token 占用先扣减，剩余预算才分配给历史消息。

## 关键代码

Token 估算和滑动窗口裁剪：

```go
type Message struct {
    Role    string `json:"role"`
    Content string `json:"content"`
    Tokens  int    `json:"-"`
}

type ContextWindow struct {
    MaxTokens    int
    SystemTokens int
    ReservedForRAG int
}

// EstimateTokens 粗略估算 Token 数（中文约 1.5 字/Token，英文约 4 字符/Token）
func EstimateTokens(text string) int {
    var cnCount, enCount int
    for _, r := range text {
        if unicode.Is(unicode.Han, r) {
            cnCount++
        } else {
            enCount++
        }
    }
    return cnCount + int(math.Ceil(float64(enCount)/4.0)) + 2 // 每条消息额外开销
}

// TrimMessages 滑动窗口裁剪，保证总 Token 不超过预算
func (cw *ContextWindow) TrimMessages(msgs []Message, ragContext string) []Message {
    budget := cw.MaxTokens - cw.SystemTokens - EstimateTokens(ragContext)
    if budget <= 0 {
        // RAG 内容过长，截断 RAG 而非历史（实际会在检索层限制）
        return msgs
    }

    // 从最新的消息往前累加，超预算就停止
    var result []Message
    used := 0
    for i := len(msgs) - 1; i >= 0; i-- {
        t := EstimateTokens(msgs[i].Content) + 4 // role 等开销
        if used+t > budget {
            break
        }
        used += t
        result = append([]Message{msgs[i]}, result...)
    }
    return result
}
```

历史摘要的异步生成：

```go
func (s *ConversationService) SummarizeOldMessages(ctx context.Context, convID string, cutoff int) {
    oldMsgs, err := s.repo.GetMessagesBefore(ctx, convID, cutoff)
    if err != nil || len(oldMsgs) == 0 {
        return
    }

    prompt := fmt.Sprintf(`请将以下对话历史压缩为一段不超过200字的摘要，保留关键事实和用户偏好：

%s`, formatMessages(oldMsgs))

    // 用便宜模型生成摘要，异步执行不阻塞主流程
    resp, err := s.llm.ChatCompletion(ctx, "gpt-4o-mini", []Message{
        {Role: "system", Content: "你是一个对话摘要助手，输出简洁的摘要。"},
        {Role: "user", Content: prompt},
    })
    if err != nil {
        s.log.Warn("summarize failed", zap.Error(err))
        return
    }
    _ = s.repo.SaveSummary(ctx, convID, resp.Content)
}
```

组装最终消息时，如果有摘要就放在 system 消息之后：

```go
func (b *PromptBuilder) Build(query string, history []Message, ragContexts []string, systemPrompt string, summary string) []Message {
    var msgs []Message
    msgs = append(msgs, Message{Role: "system", Content: systemPrompt})

    if summary != "" {
        msgs = append(msgs, Message{
            Role:    "system",
            Content: "以下是此前对话的摘要：" + summary,
        })
    }

    if len(ragContexts) > 0 {
        msgs = append(msgs, Message{
            Role:    "system",
            Content: "参考资料：\n" + strings.Join(ragContexts, "\n---\n"),
        })
    }

    msgs = append(msgs, history...)
    msgs = append(msgs, Message{Role: "user", Content: query})
    return msgs
}
```

## 踩坑与权衡

- **Token 估算精度**：生产环境用 tiktoken 的 Go 移植版（如 `tiktoken-go`）比字符估算精确，但有性能开销。我们在高并发路径用近似算法，在发送给模型前再做一次精确校验，如果超限再裁剪一轮，两者结合。
- **摘要的时效性**：摘要不是每次对话都更新，而是在历史被裁剪时触发。如果用户中途改变话题，旧摘要可能产生误导。我们给摘要加了时间标记，超过一定轮次后让模型自行判断是否参考。
- **system 消息的顺序**：有些模型对 system 消息的位置敏感，OpenAI 推荐放在最前面。我们把摘要也做成 system 消息放在系统提示之后，实测效果比混入 user/assistant 更好。
- **RAG 上下文占用**：检索返回的 chunk 数量直接影响历史预算。我们把 topK 从 8 降到 5，并限制每个 chunk 不超过 500 字，给历史对话留出足够空间。

## 小结

上下文管理的本质是在有限预算内做信息取舍。滑动窗口解决了"留多少"的问题，Token 预算解决了"能不能放下"的问题，摘要则弥补了裁剪带来的信息损失。三层配合下来，即使是几十轮的长对话，模型也能保持连贯，同时不会触发 Token 超限错误。
