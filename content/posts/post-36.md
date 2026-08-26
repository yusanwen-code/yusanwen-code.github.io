---
title: "MCP 协议接入实践：让大模型调用多源工具"
date: 2025-03-06T10:30:00+08:00
draft: false
tags: ["MCP", "工具调用", "LLM"]
categories: ["AI"]
description: "在知识库问答服务中接入 MCP，把异构工具统一为标准协议"
---

## 问题背景

知识库问答服务上线后，我们陆续接了很多工具：知识库检索、订单查询、数据集导出、学术文献检索（OpenAlex）。每个工具都是自定义的 HTTP 接口，工具描述、入参、错误返回各不相同，每接一个就要改一轮适配代码和 Prompt 里的工具清单，维护成本很高。

2024 年底 Model Context Protocol（MCP）开始流行，它定义了一套 client/server 之间发现工具、调用工具的标准 JSON-RPC 协议。我们决定把知识库问答服务的工具层改造成 MCP client，内部工具和第三方工具都以 MCP server 的形式接入，业务层只面向一套接口编程。

## 方案设计

整体上分三层：

1. **Transport 层**：支持 stdio（本地子进程）和 SSE（远程 server）两种传输，对接不同来源的工具。
2. **Session 层**：封装 MCP 的 initialize、tools/list、tools/call，维护会话状态，做超时与重试。
3. **工具适配层**：把 MCP 返回的 tool schema 转成我们统一 LLM 适配层里的 `ToolDef`，调用结果再回填给模型。

我们在知识库问答服务里维护一个 `MCPRegistry`，启动时按配置拉起或连接多个 server，把每个 server 暴露的工具注册进工具表。

```go
type MCPServerConfig struct {
    Name      string `json:"name" yaml:"name"`
    Transport string `json:"transport" yaml:"transport"` // stdio | sse
    Command   string `json:"command" yaml:"command"`     // stdio
    Args      []string `json:"args" yaml:"args"`
    URL       string `json:"url" yaml:"url"`             // sse
}

type ToolDef struct {
    Name        string
    Description string
    Parameters  map[string]any
    Server      string // 来自哪个 MCP server
}

type MCPRegistry struct {
    mu       sync.RWMutex
    sessions map[string]MCPSession
    tools    map[string]ToolDef // key: server.tool
}
```

初始化时遍历配置，对 stdio 类型用 `exec.Command` 拉起进程并通过 stdin/stdout 交换 JSON-RPC 消息；对 SSE 类型则发起长连接。握手成功后调用 `tools/list` 拉取工具清单并缓存。

工具调用时，我们先从模型返回的 tool_calls 中解析出工具名（带 server 前缀），再路由到对应 session：

```go
func (r *MCPRegistry) Call(ctx context.Context, server, tool string, args map[string]any) (string, error) {
    r.mu.RLock()
    sess, ok := r.sessions[server]
    r.mu.RUnlock()
    if !ok {
        return "", fmt.Errorf("mcp server %s not found", server)
    }
    req := map[string]any{
        "jsonrpc": "2.0",
        "id":      snowflake.NextID(),
        "method":  "tools/call",
        "params": map[string]any{
            "name":      tool,
            "arguments": args,
        },
    }
    return sess.Request(ctx, req)
}
```

在知识库问答服务的统一 LLM 适配层里，无论底层是 OpenAI、Azure 还是 VLLM，工具定义都用同一份 `ToolDef` 切片。模型选择工具后，我们区分内置函数和 MCP 工具：内置走本地函数表，MCP 走 `Registry.Call`，结果统一塞回 `role=tool` 的消息。

## 踩坑与权衡

第一个坑是 **stdio 子进程的僵尸进程问题**。早期我们没有给子进程设置进程组，主服务重启后旧的 MCP server 进程还挂着，时间一长服务器上堆了一堆 node/python 进程。后来用 `SysProcAttr{Setpgid: true}` 建独立进程组，并在关 session 时发 SIGTERM 给整个组才解决。

第二个坑是 **工具描述长度**。部分 MCP server 把整段文档塞进 description，拼到 Prompt 里 token 飙升。我们在注册阶段对 description 做截断，并要求内部 server 写工具时遵循"一句话用途 + 关键字段说明"的格式。

第三个是**流式调用与 MCP 的衔接**。知识库问答服务主对话是 SSE 流式输出，但 MCP 的 tools/call 本身是请求-响应模型。我们的做法是模型先吐出 `tool_calls` 增量，我们聚合成完整调用后再请求 MCP server，拿到结果再继续生成，前端通过自定义事件 `tool_call`、`tool_result` 展示中间状态。

最后是**安全边界**。MCP server 能访问文件系统和数据库，不能随便信任远程地址。我们只允许内网 SSE，并对 stdio server 做白名单；对工具参数做 schema 校验，防止模型把用户输入直接拼成危险命令。

## 小结

MCP 本质上是把"模型怎么发现和调用工具"这件事标准化了。接入后，知识库问答服务新增工具从改代码变成加一个 server 配置，工具的复用和独立演进都清爽很多。对我们这种多模型、多工具的企业问答场景，MCP 是目前投入产出比很高的一层抽象。
