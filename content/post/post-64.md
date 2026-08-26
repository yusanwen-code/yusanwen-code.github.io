---
title: "MCP 生态观察：从协议到工具市场"
slug: "post-64"
date: 2026-05-17T10:30:00+08:00
draft: false
tags: ["MCP","生态","工具"]
categories: ["AI"]
description: "从知识库问答服务的 MCP 工具调用实践，看协议落地与工具市场演进。"
---

## 问题背景

去年我们在知识库问答服务里做企业级知识库问答，早期工具调用是通过 Function Calling 硬编码在 Prompt 里的：每接一个内部系统（工单、报表、知识库检索），就要改一遍适配层、重新发版。工具多了之后，模型上下文里塞几十个 JSON Schema，token 浪费严重，而且不同 LLM 供应商的 Function Calling 格式还略有差异，统一适配层写得很痛苦。

MCP（Model Context Protocol）出现后，我把它看作"工具调用界的 USB-C"：客户端和工具之间不再点对点耦合，而是通过一个标准化的 Server 暴露 resources、tools、prompts。我们在知识库问答服务里把内部的检索、工单查询、数据导出等能力封成了几个 MCP Server，模型按需 discover 和 call。

## 方案与设计

MCP 的核心是三类原语：

- **Resources**：只读数据，类似文件 URI（如 `knowledge://dataset/123`）
- **Tools**：可执行函数，模型决定何时调用
- **Prompts**：预置的提示词模板，用户主动触发

我们的架构是：知识库问答服务作为 MCP Client，通过 stdio 或 SSE 连接多个 MCP Server。工具注册时不再硬编码 Schema，而是启动时 `list_tools` 拉取，再转换成各家 LLM 的 Function Calling 格式。这样加一个工具就是部署一个 Server，主服务不用动。

```go
// 知识库问答服务中 MCP Client 的简化封装
type MCPClient struct {
    conn     *client.Client
    tools    []Tool
    toolMap  map[string]Tool
}

type Tool struct {
    Name        string
    Description string
    InputSchema map[string]any
    handler     func(ctx context.Context, args map[string]any) (string, error)
}

func (c *MCPClient) LoadTools(ctx context.Context) error {
    resp, err := c.conn.ListTools(ctx, &mcp.ListToolsRequest{})
    if err != nil {
        return err
    }
    c.tools = make([]Tool, 0, len(resp.Tools))
    c.toolMap = make(map[string]Tool, len(resp.Tools))
    for _, t := range resp.Tools {
        c.tools = append(c.tools, Tool{
            Name:        t.Name,
            Description: t.Description,
            InputSchema: t.InputSchema,
        })
        c.toolMap[t.Name] = c.tools[len(c.tools)-1]
    }
    return nil
}

// 调用时把 MCP 响应转成统一 LLM 适配层的 ToolMessage
func (c *MCPClient) CallTool(ctx context.Context, name string, args map[string]any) (string, error) {
    out, err := c.conn.CallTool(ctx, mcp.CallToolParams{
        Name:      name,
        Arguments: args,
    })
    if err != nil {
        return "", err
    }
    return out.Content[0].Text, nil
}
```

工具列表加载后，我们再按当前对话场景做一次裁剪——比如知识问答场景只挂检索和文献工具，报表场景挂 SQL 查询和导出工具，避免几十个 Schema 全塞进上下文。

## 踩坑与权衡

第一，**工具描述质量直接决定调用准确率**。早期我们写的 Description 很随意（"查询数据"），模型经常选错工具或漏参数。后来要求每个工具都写清楚"做什么、什么时候用、参数含义、返回什么"，并在 Description 里给出一两个示例，准确率明显提升。这其实就是 Prompt Engineering 在工具层的延伸。

第二，**stdio vs SSE 部署**。本地开发用 stdio 很方便，但线上多实例时 stdio 要随 Client 进程拉起，隔离和扩缩容麻烦。我们内部工具用 SSE 部署成独立服务，第三方或本地脚本用 stdio，两种都要支持。

第三，**权限与审计**。MCP 让工具接入变容易了，但也意味着模型能触发的操作更多了。我们对写操作类工具（发工单、导出数据）强制加二次确认和审批流，并在知识库问答服务侧记录每次 tool call 的 trace_id、入参、结果，对接 ELK 和 Jaeger。

第四，**生态正在形成但还早期**。官方和社区已经有文件系统、数据库、Git、Slack 等 Server，但质量参差不齐，生产用前要自己过一遍代码。我判断接下来会出现"工具市场"——企业内部会有一个 MCP Registry，团队把各自的能力发布上去，就像今天的 npm 包一样被发现和复用。

## 小结

MCP 不是又一个 Agent 框架，而是一套让"模型—工具"解耦的协议。对我们做 LLM 平台的人来说，它把工具接入从"改代码发版"变成了"注册即插即用"，长期看会沉淀成企业内部的工具资产市场。下一个值得关注的问题是：当工具数量上百之后，怎么做路由、权限和版本治理。
