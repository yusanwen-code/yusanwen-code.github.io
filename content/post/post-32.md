---
title: "多轮对话上下文管理：滑动窗口与 Token 预算控制"
slug: "post-32"
date: 2025-01-02T10:30:00+08:00
draft: false
image: /images/post-32-cover.jpg
tags: ["对话","上下文","Token"]
categories: ["AI"]
description: "在 Token 限制内管理多轮对话历史的方案"
---

## 对话一长就报 400

知识库问答服务上线后，多轮对话是最常用的功能。用户连着聊二三十轮很常见，但每个模型都有上下文窗口限制（比如 4K、32K、128K）。不做控制，历史消息迟早撑爆 Token 上限，直接一个 400 错误甩回来；简单截掉最老的几条，又会丢关键上下文，模型开始"失忆"。

我们需要一套机制：在有限的 Token 预算内尽量保住关键信息，还得适配不同模型的窗口大小。

## 三层策略

方案按优先级递进，共三层。

第一层是滑动窗口：保留最近 N 轮对话（一轮 = 一条 user 加一条 assistant），默认 10 轮。最笨，但也最有效，因为大多数对话的关键信息就集中在最近几轮。

第二层是 Token 预算裁剪：窗口内的消息按 Token 数估算（tiktoken 或近似算法），超预算就从最旧的消息开始丢弃，直到总数（含系统提示和检索结果）回到限制内。

第三层是历史摘要：被裁掉的早期对话不直接扔，异步调小模型生成摘要，作为一条 system 消息注入，把主线脉络留住。

另外有条硬规则：系统提示词和 RAG 检索到的内容优先级最高，它们的 Token 先扣，剩下的预算才轮到历史消息。

![多轮对话的上下文组装与裁剪](/images/post-32-context-budget.svg)

## Token 怎么算，窗口怎么裁

估算和裁剪的代码长这样：

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
        return cnCount + int(math.Ceil(float64(enCount)/4.0)) + 2 // 每条消息额外开销
    }
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

## 被裁掉的部分压成摘要

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

## 组装顺序

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

## 几个细节

Token 估算的精度和开销要平衡。生产上用 tiktoken 的 Go 移植版（比如 `tiktoken-go`）比字符估算精确，但有性能开销。我们的折中：高并发路径用近似算法，真正发给模型之前再做一次精确校验，超限就再裁一轮。

摘要不能只加不管。摘要不是每次对话都更新，而是历史被裁剪时才触发。如果用户中途换了话题，旧摘要可能产生误导。我们给摘要加了时间标记，超过一定轮次就让模型自己判断还要不要参考。

system 消息的位置有讲究。有些模型对 system 消息的位置敏感，OpenAI 推荐放在最前面。摘要也做成 system 消息、放在系统提示之后，实测比混进 user/assistant 里效果更好。

RAG 内容会挤占历史预算。检索返回的 chunk 数量直接决定留给对话的空间，我们把 topK 从 8 降到 5，并限制每个 chunk 不超过 500 字。

## 后来

上下文管理说白了是在有限预算里做取舍：滑动窗口解决"留多少"，Token 预算解决"能不能放下"，摘要补上裁剪丢掉的信息。三层配合下来，几十轮的长对话模型也能保持连贯，Token 超限的 400 再没出现过。

> 封面图：[graymalkn / Flickr](https://www.flickr.com/photos/22244945@N00/3278868063) · CC BY 2.0
