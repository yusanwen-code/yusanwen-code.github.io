---
title: "企业级 LLM 知识库问答服务 知识库问答服务 架构总览"
date: 2024-12-18T10:30:00+08:00
draft: false
tags: ["LLM","RAG","架构设计"]
categories: ["AI"]
description: "知识库问答服务 的分层架构与核心模块设计"
---

## 问题背景

2024 年初，公司内部多个业务线都提出了接入大模型的需求：客服要做智能问答，研发要做代码助手，数据团队要做自然语言查数。每个团队各自调用 OpenAI 或本地部署的模型，不仅 Key 管理混乱，提示词和知识库也无法复用，更没有统一的鉴权和审计。

我们需要一个企业级的 LLM 知识库问答服务，对上提供统一 API，对下屏蔽不同模型供应商的差异，同时支持 RAG 检索增强、多轮对话、工具调用和流式输出。这就是 知识库问答服务 的由来。

## 方案设计

知识库问答服务 采用 Go（Gin）作为网关层，核心分为六层：

1. **接入层**：统一鉴权（复用 统一认证中心 的 JWT）、限流、SSE 流式输出。
2. **会话层**：多轮对话历史管理、Token 预算控制、对话摘要。
3. **检索层**：混合检索（BM25 + 向量）、light_rag 轻量检索、知识图谱增强。
4. **模型层**：统一 LLM 适配层，封装 OpenAI、Azure、VLLM、HuggingFace 等，支持多模型路由和降级。
5. **工具层**：MCP 工具调用、Function Calling、外部 API 编排。
6. **数据层**：PostgreSQL 存对话和元数据，Milvus/Qdrant 存向量，Redis 做缓存和会话状态。

数据集管理服务 负责文档解析和向量化（eino + pond 高并发），知识库问答服务 只做检索和生成，职责清晰。

## 关键代码

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

## 踩坑与权衡

- **流式输出的错误处理**：SSE 一旦开始写 HTTP Header，就无法再返回标准 JSON 错误。我们的做法是先同步等待模型连接成功（拿到第一个 chunk 或错误），再切换到 SSE 流；生成中途出错通过 `event: error` 事件推送，客户端统一处理。
- **检索降级**：RAG 检索偶尔因为向量库抖动超时，不能让整个问答挂掉。我们设置了 800ms 超时，超时就走纯对话模式，并在响应头标注 `X-Retrieval-Mode: fallback`，前端可以提示用户答案未基于知识库。
- **历史存储**：对话历史不适合全量塞 Redis（长对话内存占用大），采用 PostgreSQL 持久化 + Redis 缓存最近 N 轮的混合策略，超过窗口的历史通过摘要压缩。
- **模型路由**：不同模型能力差异大，简单问题用便宜模型，复杂问题路由到强模型。路由策略初期基于规则（关键词 + 长度），后续计划加一个小模型做意图分类。

## 小结

知识库问答服务 的核心价值不在于封装了多少模型，而在于把鉴权、检索、上下文、工具调用这些共性能力沉淀成平台，让业务方只需要关心自己的知识库和提示词。统一接入后，Key 管理、成本统计、审计日志都有了着落，新业务接入 LLM 的周期从周级降到了天级。
