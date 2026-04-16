---
title: "OpenAI 兼容多供应商接入：DeepSeek、通义、智谱、Kimi"
date: 2026-04-16T10:30:00+08:00
draft: false
tags: ["LLM", "多供应商", "OpenAI兼容"]
categories: ["AI"]
description: "用一个统一适配层接入 DeepSeek、通义、智谱、Kimi 等 OpenAI 兼容供应商"
---

## 问题背景

做 知识库问答服务 的时候，我们就面对一个现实：企业客户不可能只用一家大模型。有的客户数据合规要求必须用国产模型（通义、智谱、DeepSeek、Kimi、百川、文心），有的要接私有部署的 VLLM 或 HuggingFace 推理服务，还有的要按成本/质量在不同模型间路由。如果业务代码里到处直接写各家 SDK，光是认证方式、请求字段、流式格式的差异就够喝一壶，更别提换模型时改一大片。

alchemy-furnace 作为开源项目，更不能把用户绑死在某一家。我的做法是：**所有供应商一律走 OpenAI 兼容协议，用一个统一适配层屏蔽差异，业务层只认 `provider + model`。** 这篇讲这个适配层怎么设计。

## 方案/设计

一个观察：现在主流国产模型基本都提供了 OpenAI 兼容的 `/v1/chat/completions` 端点——DeepSeek、通义（DashScope 的兼容模式）、智谱、Kimi（Moonshot）、百川、文心，以及自托管的 VLLM、Ollama，都是如此。这意味着大部分供应商可以用同一套请求结构，区别只在 `base_url`、`api_key`、个别默认参数和流式 chunk 的小差异。

适配层的抽象很薄：

- `ProviderConfig`：每个供应商的 `base_url`、`api_key`（加密存储，见下一篇）、默认 model、是否支持 function calling、是否支持流式。
- `LLMClient`：统一接口，方法是 `Complete(ctx, Request) (Response, error)` 和 `Stream(ctx, Request) (<-chan Chunk, error)`。
- `Router`：根据请求里的 `provider` 字段选 client，没指定就按默认路由（比如低成本走 DeepSeek，强推理走某家高配）。

业务代码（包括炼丹引擎）完全不感知供应商：

```python
resp = await llm_client.complete(
    provider="deepseek",
    model="deepseek-chat",
    system=meta_prompt,
    user=user_prompt,
    temperature=0.7,
)
```

## 关键代码

Python 引擎里的适配层（基于 httpx，OpenAI 兼容协议）：

```python
import httpx
from typing import Protocol

class LLMClient(Protocol):
    async def complete(self, *, provider: str, model: str,
                       system: str, user: str,
                       temperature: float = 0.7,
                       tools: list[dict] | None = None) -> str: ...

PROVIDER_BASE_URLS = {
    "deepseek": "https://api.deepseek.com/v1",
    "qwen":     "https://dashscope.aliyuncs.com/compatible-mode/v1",
    "zhipu":    "https://open.bigmodel.cn/api/paas/v4",
    "kimi":     "https://api.moonshot.cn/v1",
    "baichuan": "https://api.baichuan-ai.com/v1",
    "wenxin":   "https://aip.baidubce.com/rpc/2.0/ai_custom/v1/wenxinworkshop",
    "vllm":     None,  # 自托管，从配置读
    "ollama":   "http://localhost:11434/v1",
}

class UnifiedLLMClient:
    def __init__(self, key_provider, timeout: float = 60.0):
        self._key_provider = key_provider  # 解密返回 api_key
        self._http = httpx.AsyncClient(timeout=timeout)

    async def complete(self, *, provider, model=None,
                       system, user, temperature=0.7, tools=None):
        cfg = self._config_for(provider)
        payload = {
            "model": model or cfg.default_model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": temperature,
        }
        if tools and cfg.supports_tools:
            payload["tools"] = tools

        resp = await self._http.post(
            f"{cfg.base_url}/chat/completions",
            headers={"Authorization": f"Bearer {cfg.api_key}"},
            json=payload,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]

    async def stream(self, *, provider, model=None,
                     system, user, temperature=0.7):
        cfg = self._config_for(provider)
        payload = {
            "model": model or cfg.default_model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": temperature,
            "stream": True,
        }
        async with self._http.stream(
            "POST", f"{cfg.base_url}/chat/completions",
            headers={"Authorization": f"Bearer {cfg.api_key}"},
            json=payload,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                chunk = line[6:]
                if chunk.strip() == "[DONE]":
                    break
                yield parse_sse_chunk(chunk)
```

Go 网关侧不直接调 LLM（合成逻辑在 Python），但管理供应商配置和 Key 时需要校验连通性，用标准库就能测：

```go
func (s *ProviderService) TestConnect(ctx context.Context, provider string) error {
    cfg, err := s.loadConfig(ctx, provider)
    if err != nil {
        return err
    }
    req, _ := http.NewRequestWithContext(ctx, "POST",
        cfg.BaseURL+"/chat/completions",
        strings.NewReader(`{"model":"`+cfg.DefaultModel+
            `","messages":[{"role":"user","content":"ping"}],"max_tokens":4}`))
    req.Header.Set("Authorization", "Bearer "+cfg.APIKey)
    req.Header.Set("Content-Type", "application/json")
    resp, err := s.httpCli.Do(req)
    if err != nil {
        return fmt.Errorf("connect: %w", err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != 200 {
        body, _ := io.ReadAll(resp.Body)
        return fmt.Errorf("provider %s returned %d: %s",
            provider, resp.StatusCode, body)
    }
    return nil
}
```

## 踩坑/权衡

**各家兼容程度不一**。DeepSeek 和 Kimi 的兼容做得最彻底，几乎零适配；通义的 DashScope 兼容模式个别字段（比如 `result_format`）行为和官方 OpenAI 有差异；智谱早期版本的 tool_calls 字段命名有出入；文心的 OpenAI 兼容上线较晚，历史上还要单独处理 access_token。我的策略是：**对差异点不搞大而全的分支，而是在 `ProviderConfig` 里用 capability flag 标注**（`supports_tools`、`stream_chunk_path`、`auth_style`），解析时按 flag 走，主流程保持统一。新增供应商通常只加配置，不改代码。

**流式 SSE 的坑最多**。有的供应商在 chunk 里带 `usage`，有的不带；有的会在最后一个 chunk 前插入空行；Ollama 的 `/v1` 模式和原生 `/api/chat` 字段还不一样。我统一在 `parse_sse_chunk` 里做归一化，对外只吐 `{content, tool_calls, done}`，把各家的脏活留在适配层。做 知识库问答服务 时我们在这层吃过亏，所以这次一开始就把流式归一化做扎实。

**超时和重试要按供应商调**。DeepSeek 长文本生成可能超过 30 秒，VLLM 自托管网络抖动常见，Ollama 首次加载模型要十几秒。我给每个 provider 单独配 `timeout` 和 `retry`，重试只对 5xx 和连接错误生效，4xx（尤其是 400 参数错误、429 限流）不盲目重试，避免把配额打爆。

**模型路由不要写死**。Router 支持按任务类型选供应商：炼丹的身份句生成用低温度 + 稳定模型；融合用温度稍高的模型；普通对话按用户配置走。配置存在数据库，运营可以调整，不用发版。

**Key 泄露风险**。前端调试时如果直接把供应商 base_url 和 key 暴露出去，等于把 API Key 送人。所有 LLM 调用都走 Python 引擎，浏览器只跟 Go 网关对话，key 永远不下发前端，且加密存储（下一篇详述）。

## 小结

OpenAI 兼容协议让多供应商接入从"每家一套 SDK"变成了"一套 HTTP + 少量 capability 配置"。适配层的价值不在代码量，而在它守住了业务代码的稳定性：加一个新供应商主要是配置工作，炼丹逻辑和对话逻辑完全不需要改。配合 capability flag、流式归一化、按供应商的超时重试，这套适配层既能接云端国产模型，也能接自托管的 VLLM/Ollama，给了用户和部署者最大的选择自由。
