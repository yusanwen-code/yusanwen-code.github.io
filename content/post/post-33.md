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

## 问题背景

知识库问答服务需要对接的模型来源很杂：有 OpenAI 官方 API，有走 Azure OpenAI 的企业部署，有内部用 VLLM 跑的开源模型（Qwen、DeepSeek），还有通过 HuggingFace TGI 部署的模型。每家的 API 格式、鉴权方式、流式协议都不一样，直接在业务代码里 if-else 会迅速腐烂。

更麻烦的是，业务方可能今天用 GPT-4o，明天因为成本原因切到 DeepSeek，或者高峰期自动降级到 VLLM 上的开源模型。我们需要一个统一的适配层，让上层只面对一套接口，底层模型可配置、可替换、可路由。

## 方案设计

核心思路是定义一个 `LLMProvider` 接口，所有供应商实现同一套方法。由于 OpenAI 的 API 格式已经成为事实标准，我们以它为基准定义请求/响应结构，其他供应商通过适配器转换。

关键设计：

1. **统一接口**：`ChatCompletion` 和 `ChatCompletionStream` 两个方法，输入输出结构对齐 OpenAI 格式。
2. **Provider 工厂**：根据模型名称和配置（baseURL、apiKey、apiType）创建对应的 Provider 实例。
3. **模型路由**：支持主备模型、按优先级路由、按成本路由。主模型失败时自动降级到备模型。
4. **能力声明**：每个 Provider 声明自己支持的能力（function calling、vision、json mode），路由时据此选择。

## 关键代码

统一接口定义：

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

OpenAI 兼容的 Provider 是基类，因为 VLLM、DeepSeek、通义、智谱等大多兼容 OpenAI 格式，只需要改 baseURL 和 apiKey：

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

流式方法用 SSE 解析，统一转成 `ChatChunk` channel：

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

Provider 注册和路由：

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

## 踩坑与权衡

- **Azure 的特殊处理**：Azure OpenAI 的 URL 格式和标准 OpenAI 不同（`/openai/deployments/{deployment}/chat/completions?api-version=xxx`），鉴权用 `api-key` header 而不是 `Authorization: Bearer`。我们给 Azure 单独写了一个 Provider，但复用了请求/响应结构。
- **VLLM 的流式差异**：VLLM 基本兼容 OpenAI 格式，但早期版本在 tool_calls 的 chunk 结构上有差异，delta 里的字段偶尔为空。我们在适配层做了兼容处理，对空 chunk 直接跳过。
- **HuggingFace TGI**：TGI 的消息格式和 OpenAI 差异较大（用 `inputs` 而不是 `messages`），后来 TGI 推出了 Messages API 才好一些。对于旧版本，我们写了专门的适配器转换。
- **错误重试**：不同供应商的限流错误码不同（OpenAI 是 429，Azure 也是 429 但 header 不同，VLLM 可能返回 500）。适配层统一识别可重试错误（429、500、502、503），结合指数退避重试。
- **配置热更新**：模型路由表存在配置中心，新增供应商或调整路由不需要重启服务，通过监听配置变更刷新 Router。

## 小结

统一适配层的价值在于"变化隔离"。新增一个模型供应商时，只需要实现 `LLMProvider` 接口并注册，上层业务代码完全不用改。以 OpenAI 格式为基准也是务实的选择——毕竟大部分新供应商都在主动兼容这个标准。有了这层抽象，模型切换和降级变得像配置路由一样简单。

> 封面图：[kewl / Flickr](https://www.flickr.com/photos/58411470@N00/7006904747) · CC BY 2.0
