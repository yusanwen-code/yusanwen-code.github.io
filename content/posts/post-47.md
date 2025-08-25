---
title: "大模型 API 集成中的限流、重试与降级"
date: 2025-08-25T10:30:00+08:00
categories: ["AI"]
tags: ["限流","重试","降级"]
description: "知识库问答服务 对接多家大模型时，限流重试降级的工程做法"
draft: false
---

## 问题背景

知识库问答服务 要同时对接 OpenAI、Azure、VLLM、HuggingFace 以及一堆国内供应商（DeepSeek、通义、智谱、Kimi、百川、文心），再加上私有化部署的 Ollama。每家的配额、QPS、TPM、错误码、重试语义都不一样。上线初期我们踩了一堆坑：某家供应商偶发 429，我们无脑重试把情况搞得更糟；另一家流式接口断连，整条对话直接挂掉；还有一次某供应商整体不可用，全站问答跟着挂。

我当时牵头做了一层统一的 LLM 适配层，把限流、重试、降级作为横切能力沉到这一层，业务代码只面对一个 Chat 接口。

## 方案设计

三件事分开做：

- **限流**：在客户端侧按供应商 + 模型维度做令牌桶，保守地按供应商给的配额打八折配置，避免真的触发对方 429。
- **重试**：只对明确可重试的错误（429、500、502、503、连接错误、EOF）做指数退避重试；400/401/403 这类业务错误立即抛。流式请求已经吐过 token 的不重试，因为重试会让前端重复看到字。
- **降级**：当某个供应商错误率超过阈值或熔断器打开，自动把请求路由到备用模型；非关键场景（比如标题生成、摘要）甚至可以直接返回降级文案。

## 关键代码

限流器我们用的是 `golang.org/x/time/rate`，每个供应商+模型一个 Limiter，用一个 map 管起来：

```go
type ModelKey struct {
    Provider string
    Model    string
}

type RateLimitManager struct {
    mu       sync.RWMutex
    limiters map[ModelKey]*rate.Limiter
    configs  map[ModelKey]LimiterConfig
}

func (m *RateLimitManager) Wait(ctx context.Context, key ModelKey) error {
    m.mu.RLock()
    lim, ok := m.limiters[key]
    m.mu.RUnlock()
    if !ok { return fmt.Errorf("no rate config for %s/%s", key.Provider, key.Model) }
    // Wait 会按令牌桶速率阻塞，直到拿到一个 token
    return lim.Wait(ctx)
}
```

重试封装用一个通用的 `Do` 函数，指数退避加抖动：

```go
func isRetryable(err error, resp *http.Response) bool {
    if err != nil {
        // 网络层错误、EOF、超时都重试
        return true
    }
    if resp == nil { return false }
    switch resp.StatusCode {
    case 429, 500, 502, 503, 504:
        return true
    }
    return false
}

func (c *Client) doWithRetry(ctx context.Context, req *http.Request, maxAttempt int) (*http.Response, error) {
    var resp *http.Response
    var err error
    for attempt := 0; attempt < maxAttempt; attempt++ {
        // 等令牌
        if werr := c.rateLimit.Wait(ctx, c.key); werr != nil {
            return nil, werr
        }
        resp, err = c.http.Do(req)
        if !isRetryable(err, resp) {
            return resp, err
        }
        // 流式请求一旦开始吐字节，就不能重试
        if resp != nil && resp.Header.Get("Content-Type") == "text/event-stream" {
            return resp, err
        }
        // 优先用 Retry-After，否则指数退避
        wait := backoff(attempt, resp)
        select {
        case <-ctx.Done():
            return nil, ctx.Err()
        case <-time.After(wait):
        }
    }
    return resp, err
}

func backoff(attempt int, resp *http.Response) time.Duration {
    if resp != nil {
        if ra := resp.Header.Get("Retry-After"); ra != "" {
            if sec, err := strconv.Atoi(ra); err == nil {
                return time.Duration(sec) * time.Second
            }
        }
    }
    base := time.Duration(1<<attempt) * time.Second
    jitter := time.Duration(rand.Int63n(int64(500 * time.Millisecond)))
    return base + jitter
}
```

熔断器用的是 `sony/gobreaker`，当某个供应商连续失败触发开路，直接走备用路由：

```go
type FallbackRoute struct {
    Primary  ModelKey
    Fallback ModelKey
}

func (r *Router) Chat(ctx context.Context, req ChatRequest) (*Response, error) {
    route := r.pick(req)
    resp, err := r.callWithBreaker(ctx, route.Primary, req)
    if err == nil { return resp, nil }

    // 主路失败，尝试备用
    if route.Fallback != (ModelKey{}) {
        r.logger.Warn("primary failed, fallback",
            zap.String("primary", route.Primary.Model),
            zap.Error(err))
        return r.callWithBreaker(ctx, route.Fallback, req)
    }
    return nil, err
}

func (r *Router) callWithBreaker(ctx context.Context, key ModelKey, req ChatRequest) (*Response, error) {
    cb := r.breakers.Get(key)
    res, err := cb.Execute(func() (interface{}, error) {
        return r.clients.Get(key).Chat(ctx, req)
    })
    if err != nil { return nil, err }
    return res.(*Response), nil
}
```

## 踩坑与权衡

第一个坑是 429 重试风暴。某家供应商偶发限流时，我们所有并发请求一起退避、一起重试，反而把下一秒的配额瞬间打爆。后来加了抖动（jitter），把重试时刻打散，并且尊重 `Retry-After` 头，问题才缓解。

第二个坑是非幂等重试。聊天接口如果请求体里带了 `request_id` 之类的字段，重试一般安全；但有些供应商不支持，重试会产生重复扣费。我们的做法是给每次对话生成业务侧的 `idempotency_key`，能传就传，不能传的供应商就只在网络错误阶段重试，一旦拿到 HTTP 响应就不再重试。

第三个是流式响应的半成功状态。SSE 流可能已经吐了几个 token 才断开，前端已经渲染了。这时候重试会让用户看到重影。我们的策略是：在第一个 chunk 到达之前断开，可以安全重试；一旦有 chunk 输出，就直接把错误抛给前端，让前端显示"输出中断，点此重试"。

第四个是降级模型选择。备用模型不是随便选的——主模型是强推理模型，降级到小模型可能答非所问。我们按"能力档位"配置路由：主路不可用时选同档位的另一家，而不是无条件降级到最便宜的模型。

第五个是熔断器的敏感度。一开始阈值设太严，偶发一次 500 就开路，误伤严重。最后调整为"连续 5 次失败或 60 秒内错误率超过 50%"才开路，半开探测放 1 个请求，稳定多了。

## 小结

LLM 集成真正的稳定性问题，绝大多数不在模型本身，而在它周边的网络和配额。统一适配层 + 令牌桶限流 + 有选择的指数退避重试 + 熔断器驱动的多供应商降级，让 知识库问答服务 在任何一家供应商出问题时都能"带病工作"，业务侧基本无感。
