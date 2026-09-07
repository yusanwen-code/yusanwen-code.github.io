---
title: "统一 LLM API 适配层：封装 OpenAI、Azure、VLLM、HuggingFace"
slug: "post-33"
date: 2025-01-18T10:30:00+08:00
draft: false
image: /images/post-33-cover.jpg
tags: ["LLM","适配层","OpenAI"]
categories: ["AI"]
description: "用统一接口屏蔽多模型供应商差异的设计"
---

## 模型来源有多杂

知识库问答服务要对接的模型来源很杂：OpenAI 官方 API、走 Azure OpenAI 的企业部署、内部用 VLLM 跑的开源模型（Qwen、DeepSeek），还有通过 HuggingFace TGI 部署的模型。四路来源，API 格式、鉴权方式、流式协议各是各的。

直接在业务代码里 if-else 是能写，但会迅速腐烂：每接一家加一层判断，很快就没法看了。

麻烦还不止格式。业务方可能今天用 GPT-4o，明天因为成本切到 DeepSeek，高峰期还得自动降级到 VLLM 上的开源模型。切换和降级这种事，不该每次都拉着业务代码一起改。

所以我们做了一个统一的适配层：上层只面对一套接口，底层模型可配置、可替换、可路由。

## 拿 OpenAI 格式当基准

核心思路是定义一个 `LLMProvider` 接口，所有供应商实现同一套方法。以谁为基准？OpenAI。它的 API 格式已经是事实标准，请求和响应结构就按它定义，其他供应商通过适配器转换。

整套设计里要紧的就四件事：

1. 统一接口：`ChatCompletion` 和 `ChatCompletionStream` 两个方法，输入输出结构对齐 OpenAI 格式；
2. Provider 工厂：根据模型名称和配置（baseURL、apiKey、apiType）创建对应的 Provider 实例；
3. 模型路由：支持主备模型、按优先级路由、按成本路由，主模型失败时自动降级到备模型；
4. 能力声明：每个 Provider 声明自己支持的能力（function calling、vision、json mode），路由时据此选择。

![统一 LLM 适配层的整体结构](/images/post-33-llm-adapter.svg)

## 一个接口，两个方法

接口定义本身很短：

```go
type LLMProvider interface {
    Name() string
    ChatCompletion(ctx context.Context, model string, msgs []Message, opts ...CallOption) (*ChatResponse, error)
    ChatCompletionStream(ctx context.Context, model string, msgs []Message, opts ...CallOption) (<-chan ChatChunk, error)
    Supports(capability Capability) bool
}

type Capability string

const (
    CapFunctionCalling Capability = "function_calling"
    CapVision          Capability = "vision"
    CapJSONMode        Capability = "json_mode"
    CapStreaming       Capability = "streaming"
)
```

OpenAI 兼容的 Provider 是基类，因为 VLLM、DeepSeek、通义、智谱这些大多兼容 OpenAI 格式，只需要改 baseURL 和 apiKey：

```go
type OpenAICompatibleProvider struct {
    name       string
    baseURL    string
    apiKey     string
    httpClient *http.Client
    caps       map[Capability]bool
}

func (p *OpenAICompatibleProvider) ChatCompletion(ctx context.Context, model string, msgs []Message, opts ...CallOption) (*ChatResponse, error) {
    cfg := applyOptions(opts...)
    body := openAIChatRequest{
        Model:       model,
        Messages:    toOpenAIMessages(msgs),
        Temperature: cfg.Temperature,
        MaxTokens:   cfg.MaxTokens,
        Stream:      false,
    }
    if cfg.JSONMode {
        body.ResponseFormat = &openAIResponseFormat{Type: "json_object"}
    }

    data, _ := json.Marshal(body)
    req, err := http.NewRequestWithContext(ctx, "POST", p.baseURL+"/chat/completions", bytes.NewReader(data))
    if err != nil {
        return nil, err
    }
    req.Header.Set("Authorization", "Bearer "+p.apiKey)
    req.Header.Set("Content-Type", "application/json")

    resp, err := p.httpClient.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    if resp.StatusCode >= 400 {
        return nil, parseAPIError(resp)
    }

    var raw openAIChatResponse
    if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
        return nil, err
    }
    return fromOpenAIResponse(&raw), nil
}
```

流式是另一条路径。SSE 逐行解析，统一转成 `ChatChunk` channel：

```go
func (p *OpenAICompatibleProvider) ChatCompletionStream(ctx context.Context, model string, msgs []Message, opts ...CallOption) (<-chan ChatChunk, error) {
    // 请求构造同上，Stream 设为 true
    // 发起请求后逐行读取 SSE，解析 data: {...} 行
    out := make(chan ChatChunk, 32)
    go func() {
        defer close(out)
        scanner := bufio.NewScanner(resp.Body)
        for scanner.Scan() {
            line := scanner.Text()
            if !strings.HasPrefix(line, "data: ") {
                continue
            }
            payload := strings.TrimPrefix(line, "data: ")
            if payload == "[DONE]" {
                return
            }
            var chunk openAIChunk
            if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
                continue
            }
            if len(chunk.Choices) > 0 {
                out <- ChatChunk{
                    Content: chunk.Choices[0].Delta.Content,
                    Role:    chunk.Choices[0].Delta.Role,
                }
            }
        }
    }()
    return out, nil
}
```

## 路由怎么挑 Provider

Provider 注册进来之后，剩下的问题是请求来了发给谁。Router 维护一张模型别名到 Provider 名的映射，按需检查能力声明：

```go
type Router struct {
    providers map[string]LLMProvider
    routes    map[string]string // modelAlias -> providerName
}

func (r *Router) Register(name string, p LLMProvider) {
    r.providers[name] = p
}

func (r *Router) Route(modelName string, requiredCaps ...Capability) (LLMProvider, error) {
    providerName, ok := r.routes[modelName]
    if !ok {
        return nil, fmt.Errorf("no route for model: %s", modelName)
    }
    p := r.providers[providerName]
    for _, cap := range requiredCaps {
        if !p.Supports(cap) {
            // 降级：找一个支持该能力的备用 Provider
            if fallback := r.findFallback(cap); fallback != nil {
                return fallback, nil
            }
            return nil, fmt.Errorf("provider %s missing capability %s", providerName, cap)
        }
    }
    return p, nil
}
```

`Route` 里值得说的是降级逻辑：主 Provider 缺某个能力时，先找支持该能力的备用 Provider，实在找不到才报错。能力声明在这时候起作用，路由不只看名字，还要看这个 Provider 真能干这件事。

## 各家的脾气

真正花时间的不是写接口，是抹平各家差异。

Azure OpenAI 是第一个绕不开的：URL 格式和标准 OpenAI 不同，是 `/openai/deployments/{deployment}/chat/completions?api-version=xxx` 这种带部署名的路径；鉴权也不用 `Authorization: Bearer`，而是 `api-key` header。我们给 Azure 单独写了一个 Provider，好在请求和响应结构可以复用。

VLLM 基本兼容 OpenAI 格式，但早期版本在 tool_calls 的 chunk 结构上有差异，delta 里的字段偶尔为空。适配层对空 chunk 直接跳过，算是低成本的兼容处理。

HuggingFace TGI 的消息格式差异更大，用 `inputs` 而不是 `messages`。后来 TGI 推出了 Messages API，情况好了不少；旧版本我们还是写了专门的适配器来转换。

错误处理也得统一。同样是限流，OpenAI 返回 429，Azure 也是 429 但 header 不同，VLLM 可能直接给个 500。适配层把 429、500、502、503 统一识别为可重试错误，配指数退避重试。

最后是配置热更新。模型路由表放在配置中心，新增供应商、调整路由都不用重启服务，监听配置变更刷新 Router 就行。模型切换变成改配置的事，这层适配最直接的收益就在这。

## 回头看

这层抽象的价值就是"变化隔离"：新增一个模型供应商，实现 `LLMProvider` 接口然后注册，上层业务代码一行不动。以 OpenAI 格式为基准也是务实的，大部分新供应商都在主动兼容这个标准。有了这一层，模型切换和降级，跟改一条路由配置是一个难度的事。

> 封面图：[kewl / Flickr](https://www.flickr.com/photos/58411470@N00/7006904747) · CC BY 2.0
