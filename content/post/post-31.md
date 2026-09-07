---
title: "企业级 LLM 问答服务架构总览"
slug: "post-31"
date: 2024-12-18T10:30:00+08:00
draft: false
image: /images/post-31-cover.jpg
tags: ["LLM","RAG","架构设计"]
categories: ["AI"]
description: "知识库问答服务的分层架构与核心模块设计"
---

## 各自管 Key 的日子

2024 年初，公司内部好几条业务线都想接大模型：客服要做智能问答，研发要做代码助手，数据团队要做自然语言查数。各团队自己调 OpenAI 或本地部署的模型，结果就是 Key 管理混乱，提示词和知识库没法复用，鉴权和审计更谈不上。

所以我们做了一个企业级的知识库问答服务：对上提供统一 API，对下屏蔽不同模型供应商的差异，RAG 检索增强、多轮对话、工具调用、流式输出都收进来。

## 六层，各管一摊

服务用 Go（Gin）做网关层，从上到下分六层：

1. 接入层：统一鉴权（复用统一认证中心的 JWT）、限流、SSE 流式输出；
2. 会话层：多轮对话历史管理、Token 预算控制、对话摘要；
3. 检索层：混合检索（BM25 + 向量）、light_rag 轻量检索、知识图谱增强；
4. 模型层：统一 LLM 适配层，封装 OpenAI、Azure、VLLM、HuggingFace 等，支持多模型路由和降级；
5. 工具层：MCP 工具调用、Function Calling、外部 API 编排；
6. 数据层：PostgreSQL 存对话和元数据，Milvus/Qdrant 存向量，Redis 做缓存和会话状态。文档解析和向量化不在本服务里，交给数据集管理服务做（eino + pond 高并发），问答服务只做检索和生成，职责清楚。

![知识库问答服务的六层架构](/images/post-31-llm-arch.svg)

## 网关入口

网关入口的路由注册和中间件链：

```go
func NewRouter(h *Handler, auth *AuthMiddleware) *gin.Engine {
    r := gin.New()
    r.Use(gin.Recovery(), zaplogger.GinLogger(), auth.Verify())

    v1 := r.Group("/api/v1")
    {
        v1.POST("/chat/completions", h.ChatCompletions)      // 类 OpenAI 接口
        v1.POST("/chat/stream", h.ChatStream)               // SSE 流式
        v1.GET("/conversations/:id", h.GetConversation)
        v1.POST("/conversations/:id/messages", h.SendMessage)
        v1.POST("/tools/call", h.CallTool)                  // MCP 工具
    }
    return r
}
```

## 对话主流程

对话主流程的编排（伪代码，展示核心链路）：

```go
func (h *Handler) ChatStream(c *gin.Context) {
    var req ChatRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        respondError(c, 400, err)
        return
    }

    // 1. 加载历史 + 滑动窗口裁剪
    history, err := h.convSvc.LoadHistory(c, req.ConversationID, req.TokenBudget)
    if err != nil {
        respondError(c, 500, err)
        return
    }

    // 2. RAG 检索
    contexts, err := h.retriever.Retrieve(c, req.Query, req.KnowledgeBaseIDs,
        retriever.WithHybrid(true), retriever.WithTopK(5))
    if err != nil {
        // 检索降级：不阻断主流程，用纯对话兜底
        h.log.Warn("retrieve failed, fallback to chat-only", zap.Error(err))
    }

    // 3. 构造消息
    messages := h.promptBuilder.Build(req.Query, history, contexts, req.SystemPrompt)

    // 4. 选择模型 + 流式生成
    model := h.router.Route(req.Model, req.Priority)
    stream, err := h.llm.ChatCompletionStream(c, model, messages)
    if err != nil {
        respondError(c, 502, err)
        return
    }

    // 5. SSE 推流 + 异步落库
    c.Stream(func(w io.Writer) bool {
        chunk, ok := <-stream
        if !ok {
            go h.convSvc.SaveMessage(req.ConversationID, messages, accumulated)
            return false
        }
        accumulated += chunk.Content
        c.SSEvent("message.delta", chunk)
        return true
    })
}
```

## 四个权衡

SSE 的错误处理是个坑：Header 一旦写出去，就回不去标准 JSON 错误了。所以先同步等模型连接成功——拿到第一个 chunk 或错误——再切换到 SSE 流；生成中途出错，用 `event: error` 事件推给客户端，客户端统一按事件处理。

检索不能绑架主流程。向量库偶尔抖动超时，不能让整个问答跟着挂。检索设了 800ms 超时，超时就走纯对话模式，并在响应头标注 `X-Retrieval-Mode: fallback`，前端可以提示用户：这条答案没过知识库。

对话历史不全塞 Redis。长对话的内存占用大，最后是 PostgreSQL 持久化 + Redis 缓存最近 N 轮的混合策略，超出窗口的历史通过摘要压缩。

模型路由先规则后智能。简单问题给便宜模型，复杂问题路由到强模型。路由策略初期基于规则（关键词 + 长度），后续计划加一个小模型做意图分类。

## 后来

回头看，这个服务的价值不在封装了多少个模型，而在把鉴权、检索、上下文、工具调用这些共性能力沉淀成平台，让业务方只需要关心自己的知识库和提示词。统一接入后，Key 管理、成本统计、审计日志都有了着落，新业务接入 LLM 的周期从周级降到了天级。

> 封面图：[robert.claypool / Flickr](https://www.flickr.com/photos/35106989@N08/6780155266) · CC BY 2.0
