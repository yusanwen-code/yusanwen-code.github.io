---
title: "MCP 协议接入实践：让大模型调用多源工具"
slug: "post-36"
date: 2025-03-06T10:30:00+08:00
draft: false
image: /images/post-36-cover.jpg
tags: ["MCP", "工具调用", "LLM"]
categories: ["AI"]
description: "在知识库问答服务中接入 MCP，把异构工具统一为标准协议"
---

## 每接一个工具，就得改一轮

知识库问答服务上线后，陆陆续续接了不少工具：知识库检索、订单查询、数据集导出、学术文献检索（OpenAlex）。每个工具都是自定义的 HTTP 接口，工具描述、入参、错误返回各写各的。更要命的是，每接一个，适配代码要改一轮，Prompt 里的工具清单也得跟着改一轮，工具越多维护越累。

2024 年底 Model Context Protocol（MCP）开始流行。它定义了一套 client/server 之间发现工具、调用工具的标准 JSON-RPC 协议，把"模型怎么发现和调用工具"这件事标准化了。我们决定把知识库问答服务的工具层改造成 MCP client：内部工具和第三方工具都以 MCP server 的形式接入，业务层只面向一套接口编程。

## 三层：Transport、Session、工具适配

1. Transport 层：支持 stdio（本地子进程）和 SSE（远程 server）两种传输，对接不同来源的工具；
2. Session 层：封装 MCP 的 initialize、tools/list、tools/call，维护会话状态，做超时与重试；
3. 工具适配层：把 MCP 返回的 tool schema 转成统一 LLM 适配层里的 `ToolDef`，调用结果再回填给模型。

服务里维护一个 `MCPRegistry`，启动时按配置拉起或连接多个 server，把每个 server 暴露的工具注册进工具表。

![MCP 接入：Registry、双传输与一次工具调用](/images/post-36-mcp-arch.svg)

## 注册表与会话

配置结构和工具定义长这样：

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

初始化时遍历配置：stdio 类型用 `exec.Command` 拉起进程，通过 stdin/stdout 交换 JSON-RPC 消息；SSE 类型发起长连接。握手成功后调 `tools/list` 拉取工具清单并缓存。

工具调用时，先从模型返回的 tool_calls 里解析出工具名（带 server 前缀），再路由到对应 session：

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

工具定义在统一 LLM 适配层里只有一份 `ToolDef` 切片，底下是 OpenAI、Azure 还是 VLLM 都无所谓。模型选完工具后分两类：内置函数走本地函数表，MCP 工具走 `Registry.Call`，结果统一塞回 `role=tool` 的消息。

## 四个坑

第一个坑是 stdio 子进程变僵尸。早期没给子进程设置进程组，主服务重启后旧的 MCP server 进程还挂着，时间一长服务器上堆了一堆 node、python 进程。后来用 `SysProcAttr{Setpgid: true}` 建独立进程组，关 session 时给整个组发 SIGTERM，才解决。

第二个坑是工具描述长度。有的 MCP server 把整段文档塞进 description，拼进 Prompt 里 token 直接飙升。现在注册阶段对 description 做截断，也要求内部 server 写工具时遵循"一句话用途加关键字段说明"的格式。

第三个是流式调用和 MCP 的衔接。主对话是 SSE 流式输出，但 MCP 的 tools/call 是请求-响应模型，两边节奏对不上。我们的做法：模型先吐出 `tool_calls` 增量，聚合成完整调用后再请求 MCP server，拿到结果继续生成；前端通过自定义事件 `tool_call`、`tool_result` 展示中间状态，用户能看见模型正在调什么。

最后是安全边界。MCP server 能访问文件系统和数据库，不能随便信任远程地址。我们只允许内网 SSE，stdio server 做白名单；工具参数做 schema 校验，防止模型把用户输入直接拼成危险命令。

## 接入之后

新增工具从改代码变成加一个 server 配置，工具的复用和独立演进都清爽了很多。对我们这种多模型、多工具的企业问答场景，这层抽象的投入产出比目前看是很高的。

> 封面图：[qubodup / Flickr](https://www.flickr.com/photos/21051491@N02/23636230004) · CC BY 2.0
