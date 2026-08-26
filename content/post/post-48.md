---
title: "流式输出 SSE：从 LLM 到前端的打字机效果"
slug: "post-48"
date: 2025-09-09T10:30:00+08:00
categories: ["AI"]
tags: ["SSE","流式","LLM"]
description: "知识库问答服务里用 SSE 把 LLM token 实时推到前端的细节"
draft: false
---

## 问题背景

知识库问答服务最初的问答接口是一次性返回完整答案。一个复杂问题，LLM 要生成七八秒甚至更久，前端转圈等待，体验很差。更糟的是，模型如果在最后一步因为 token 超限报错，用户白等半天。

我当时把问答接口改造成 SSE（Server-Sent Events）流式：后端一边接收 LLM 的 token，一边往前端推。用户看到的是打字机效果，首字延迟（TTFT）从七八秒压到一秒以内。这篇讲讲中间的工程细节。

## 方案设计

链路是这样的：浏览器 → Hertz/Gin 后端 → LLM 供应商的流式接口。后端的角色不只是透传，还要做几件事：

1. 统一多家供应商的 SSE 格式（OpenAI 风格的 `data: {...}\n\n`）。
2. 支持中途中断：用户点"停止"，后端要能把到 LLM 的连接也关掉。
3. 在流里穿插业务事件（检索命中的文档、工具调用状态、最终 trace ID），不只是 token。
4. 处理代理和网关的缓冲问题——很多反向代理默认会 buffer 响应，导致打字机变一坨。

## 关键代码

Gin 侧，SSE 的核心是手动设置 Header 并 flush：

```go
func (h *ChatHandler) Stream(c *gin.Context) {
    var req ChatRequest
    if err := c.ShouldBindJSON(&req); err != nil { c.JSON(400, err); return }

    c.Writer.Header().Set("Content-Type", "text/event-stream")
    c.Writer.Header().Set("Cache-Control", "no-cache")
    c.Writer.Header().Set("Connection", "keep-alive")
    c.Writer.Header().Set("X-Accel-Buffering", "no") // 关键：禁 Nginx 缓冲

    flusher, ok := c.Writer.(http.Flusher)
    if !ok { c.JSON(500, "stream unsupported"); return }

    // 把 ctx 传给下游，用户断开时会被 cancel
    ctx := c.Request.Context()

    // 先推一帧"检索中"事件，让前端有反馈
    writeEvent(c.Writer, "status", "检索相关文档...")
    flusher.Flush()

    stream, err := h.llm.ChatStream(ctx, req)
    if err != nil {
        writeEvent(c.Writer, "error", err.Error())
        return
    }
    defer stream.Close()

    for {
        chunk, err := stream.Recv()
        if err == io.EOF {
            writeEvent(c.Writer, "done", "")
            flusher.Flush()
            return
        }
        if err != nil {
            // ctx 被取消说明是用户主动断开，不算错误
            if ctx.Err() != nil { return }
            writeEvent(c.Writer, "error", err.Error())
            flusher.Flush()
            return
        }
        // 把 delta 推给前端
        writeEvent(c.Writer, "delta", chunk.Delta)
        flusher.Flush()
    }
}

func writeEvent(w io.Writer, event, data string) {
    fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, data)
}
```

对下统一 LLM 流，OpenAI 兼容的供应商用 `http` 直接读，VLLM、Ollama 也都兼容这个协议：

```go
func (c *OpenAIClient) ChatStream(ctx context.Context, req ChatRequest) (Stream, error) {
    body, _ := json.Marshal(adaptRequest(req, true)) // stream=true
    httpReq, _ := http.NewRequestWithContext(ctx, "POST", c.baseURL+"/chat/completions", bytes.NewReader(body))
    httpReq.Header.Set("Authorization", "Bearer "+c.apiKey)
    httpReq.Header.Set("Content-Type", "application/json")
    httpReq.Header.Set("Accept", "text/event-stream")

    resp, err := c.http.Do(httpReq)
    if err != nil { return nil, err }
    return &openAIStream{reader: bufio.NewReader(resp.Body), body: resp.Body}, nil
}

func (s *openAIStream) Recv() (*Chunk, error) {
    for {
        line, err := s.reader.ReadBytes('\n')
        if err != nil { return nil, err }
        line = bytes.TrimSpace(line)
        if len(line) == 0 { continue }
        if !bytes.HasPrefix(line, []byte("data:")) { continue }
        payload := bytes.TrimSpace(line[5:])
        if bytes.Equal(payload, []byte("[DONE]")) { return nil, io.EOF }
        var chunk openAIChunk
        if err := json.Unmarshal(payload, &chunk); err != nil { continue }
        if len(chunk.Choices) == 0 { continue }
        return &Chunk{Delta: chunk.Choices[0].Delta.Content}, nil
    }
}
```

前端用标准 EventSource 或 fetch + ReadableStream，POST + body 时 EventSource 不支持，我们用 fetch：

```js
const resp = await fetch('/api/chat/stream', {
  method: 'POST',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify(req),
});
const reader = resp.body.getReader();
const decoder = new TextDecoder();
let buffer = '';
while (true) {
  const {value, done} = await reader.read();
  if (done) break;
  buffer += decoder.decode(value, {stream: true});
  const frames = buffer.split('\n\n');
  buffer = frames.pop();
  for (const frame of frames) {
    const event = /event: (.+)/.exec(frame)?.[1];
    const data  = /data: (.+)/.exec(frame)?.[1];
    if (event === 'delta') appendToken(data);
    else if (event === 'done') finish();
    else if (event === 'error') showError(data);
  }
}
```

## 踩坑与权衡

最经典的坑是代理缓冲。Nginx、API 网关、CDN 默认会缓存响应，攒到一定大小才转发，SSE 的"实时"就没了。我们在响应里加了 `X-Accel-Buffering: no`（Nginx 认这个头），并在 KubeSphere 的 Ingress 注解里显式关掉 proxy buffering，才真正做到逐字出现。

第二个坑是心跳。如果 LLM 正在"思考"（尤其是工具调用阶段），几十秒没有数据，中间的代理或 LB 可能直接掐断连接。我们每 15 秒发一个注释帧 `": keepalive\n\n"`，SSE 协议里以冒号开头的行是注释，前端会忽略，但能保活。

第三个坑是用户主动取消。浏览器关掉页面或点停止，`ctx.Done()` 会触发，但很多人忘了把这个取消传递给下游 LLM 请求——结果后端还在默默接收 token，浪费 token 配额。我们用 `http.NewRequestWithContext` 把整个 ctx 链透传下去，断开时对 LLM 的连接会被立即关闭。

第四个是错误恢复。流式过程中网络断了，已经吐出来的字不能回退。我们的策略是在最后一帧 `done` 里带完整消息 ID，前端如果没收到 done 但连接断了，就标"输出中断"，用户可以点"重新生成"，这比悄悄少半截要好。

第五个权衡：gRPC streaming vs SSE。内部服务之间我们用 gRPC streaming，对外暴露给浏览器的接口选 SSE——纯 HTTP、浏览器原生支持、穿透代理友好，比 WebSocket 轻量得多。

## 小结

SSE 看起来简单，就是"写一点 flush 一点"，但真正做到稳定可用，要处理代理缓冲、心跳保活、取消传播、错误帧、多供应商格式统一这一整套细节。知识库问答服务改成流式后，用户主观体验的提升远大于我们投入的改造工作量，也成了后来所有 LLM 接口的默认输出方式。
