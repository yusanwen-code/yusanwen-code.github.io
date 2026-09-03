---
title: "Function Calling 在企业工具调用场景的工程化"
slug: "post-38"
date: 2025-04-06T10:30:00+08:00
draft: false
image: /images/post-38-cover.jpg
tags: ["Function Calling", "工具调用", "LLM"]
categories: ["AI"]
description: "把 Function Calling 从 demo 做成生产可用的工具调用框架"
---

## 问题背景

知识库问答服务最早的工具调用是把工具列表拼在 system prompt 里让模型自己输出 JSON，结果模型经常漏字段、把枚举值写错、甚至输出一段自然语言而不是 JSON。OpenAI 兼容协议都支持 Function Calling 后，我们切换到原生 tool_calls，但生产环境又冒出新问题：模型选错工具、参数不合法、工具执行超时、多轮调用陷入死循环。

这篇讲我们怎么把 Function Calling 从"能跑通"做成"生产可用"。

## 方案设计

我们抽象了一个 `Tool` 接口，所有工具实现它，框架负责注册、schema 生成、参数校验、执行和结果回填：

```go
type Tool interface {
    Name() string
    Description() string
    Schema() *jsonschema.Schema // 入参 JSON Schema
    Invoke(ctx context.Context, args json.RawMessage) (any, error)
}

type Registry struct {
    tools map[string]Tool
}

func (r *Registry) Definitions() []openai.Tool {
    defs := make([]openai.Tool, 0, len(r.tools))
    for _, t := range r.tools {
        defs = append(defs, openai.Tool{
            Type: "function",
            Function: openai.FunctionDefinition{
                Name:        t.Name(),
                Description: t.Description(),
                Parameters:   t.Schema(),
            },
        })
    }
    return defs
}
```

每个工具自己声明入参 struct，用 tag 生成 JSON Schema，避免手写 schema 与代码脱节：

```go
type SearchDatasetArgs struct {
    DatasetID string `json:"dataset_id" jsonschema:"required,description=数据集ID"`
    Query     string `json:"query" jsonschema:"required,description=检索关键词"`
    TopK      int    `json:"top_k" jsonschema:"description=返回条数,default=5"`
}

func (s *SearchDatasetTool) Schema() *jsonschema.Schema {
    return jsonschema.Reflect(&SearchDatasetArgs{})
}
```

执行循环是 Function Calling 的核心。我们在一次用户请求内维护一个 `maxIterations`（默认 5），每次拿到模型响应后：

1. 如果没有 `tool_calls`，把内容作为最终回答返回；
2. 如果有，逐个执行工具，把结果以 `role=tool` 消息追加到对话历史；
3. 再次请求模型，直到模型不再调用工具或达到迭代上限。

```go
for iter := 0; iter < maxIter; iter++ {
    resp, err := s.llm.Chat(ctx, msgs, tools)
    if err != nil {
        return nil, err
    }
    if len(resp.ToolCalls) == 0 {
        return resp.Content, nil
    }
    for _, call := range resp.ToolCalls {
        tool, ok := reg.Get(call.Function.Name)
        if !ok {
            msgs = append(msgs, toolErrMsg(call.ID, "tool not found"))
            continue
        }
        if err := validateArgs(tool.Schema(), call.Function.Arguments); err != nil {
            msgs = append(msgs, toolErrMsg(call.ID, err.Error()))
            continue
        }
        result, err := invokeWithTimeout(ctx, tool, call.Function.Arguments)
        if err != nil {
            msgs = append(msgs, toolErrMsg(call.ID, err.Error()))
            continue
        }
        msgs = append(msgs, openai.ToolMessage(call.ID, result))
    }
}
```

## 踩坑与权衡

**参数校验必须做**。即使有 schema，模型仍会输出类型错误或枚举外的值。我们在执行前用 JSON Schema 校验，校验失败不直接报错给用户，而是把错误信息作为 tool result 回给模型，让它自我修正——通常一到两轮就能改对。

**严格控制工具数量和描述质量**。工具一多，模型选错的概率线性上升。我们的经验是单次对话注入的工具不超过 15 个；工具名用动宾结构（`search_dataset`、`export_order`），description 写清"什么时候用、什么时候不要用"，比写参数说明更能降低误调用。

**执行隔离与超时**。工具可能查数据库、调第三方接口，不能让一个慢工具拖垮整个会话。每个工具执行都包一层带超时的 context，并用带缓冲的 channel 接收结果，超时就返回错误让模型决定是否重试。

**防死循环**。除了 `maxIterations`，我们还记录每次调用的工具名+参数 hash，连续两次完全相同的调用直接中断，避免模型用同样的参数反复撞同一个错误。

**结果裁剪**。有些工具（如 SQL 查询、文献检索）返回数据量很大，直接塞回上下文会爆 token。我们在工具层统一做结果裁剪和结构化摘要，只把与问题相关的前 N 条和总命中数返回给模型，完整结果通过引用 ID 让前端按需拉取。

## 小结

Function Calling 的工程化重点不在"调通接口"，而在围绕模型不确定性做防御：schema 校验、执行隔离、迭代上限、结果裁剪。知识库问答服务用统一的 Tool 接口和执行循环把这些横切逻辑收敛到框架里，新增业务工具只需要实现接口、写好描述，就能安全地交给模型调用。

> 封面图：[M McBey / Flickr](https://www.flickr.com/photos/158652122@N02/49467795397) · CC BY 2.0
