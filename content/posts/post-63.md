---
title: "API Key 加密存储与演示模式内存 Mock 的设计"
date: 2026-05-02T10:30:00+08:00
draft: false
tags: ["加密", "Mock", "API Key"]
categories: ["安全"]
description: "供应商 API Key 的 AES-GCM 加密存储，以及 DEMO_MODE 下的内存 Mock"
---

## 问题背景

alchemy-furnace 要接 DeepSeek、通义、智谱、Kimi 等多家供应商，用户得在控制台填自己的 API Key。这些 Key 一旦明文存进 MySQL，等于把后门钥匙交给了任何能读到库的人——备份泄露、运维误操作、SQL 注入，任何一环都可能造成真实资金损失。在统一支付平台做支付平台时我对"敏感数据绝不能明文落库"有切身体会，签名密钥、商户私钥那一套都要加密。

另一个现实问题是开源项目的演示体验。我希望放一个在线 DEMO，访客不用配任何 Key 就能点几下体验炼丹流程，但 DEMO 绝不能真的扣我的 API 额度，更不能让访客通过 DEMO 触发任意 LLM 调用。于是有了 `DEMO_MODE`：开启后所有 LLM 调用走内存 Mock，不碰任何真实供应商。这篇讲这两块的设计。

## 方案/设计

**加密存储**：对称加密用 AES-256-GCM，它自带认证标签，能防篡改。主密钥（master key）不放数据库，通过环境变量 `FURNACE_MASTER_KEY` 注入，K8s 里用 Secret 管理。每条 Provider 配置存的是：

- `key_ciphertext`：AES-GCM 加密后的 API Key（base64）
- `key_nonce`：每次加密随机生成的 nonce
- `key_version`：主密钥版本，支持轮转
- 不存明文，不存主密钥

为了支持主密钥轮转，我维护一个 `key_version -> master_key` 的映射（环境变量 `FURNACE_MASTER_KEY_V1`、`_V2`），加密时用最新版本，解密时按记录里的版本取对应密钥。轮转时跑一个后台任务把旧密文用新密钥重加密，不需要停机。

**DEMO_MODE**：一个布尔配置。开启后：

- `LLMClient` 被替换成 `MockLLMClient`，不发任何 HTTP 请求，直接返回基于输入生成的假响应（带合理延迟，模拟流式）。
- 供应商 Key 校验接口直接返回"演示模式，未配置真实 Key"。
- 数据库用 SQLite 内存库或独立的 demo 库，数据不与生产混用。
- 演示模式下创建的金丹、分身带 `demo=true` 标记，避免被误当成真实数据。

## 关键代码

Go 侧的加密服务：

```go
type CryptoService struct {
    keys map[int][]byte // version -> key
    latestVer int
}

func NewCryptoService(m map[int][]byte) *CryptoService {
    return &CryptoService{keys: m, latestVer: findLatest(m)}
}

func (c *CryptoService) Encrypt(plaintext string) (
    ciphertext string, nonce string, ver int, err error,
) {
    ver = c.latestVer
    key := c.keys[ver]
    block, err := aes.NewCipher(key)
    if err != nil {
        return "", "", 0, err
    }
    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return "", "", 0, err
    }
    n := make([]byte, gcm.NonceSize())
    if _, err := rand.Read(n); err != nil {
        return "", "", 0, err
    }
    ct := gcm.Seal(nil, n, []byte(plaintext), nil)
    return base64.StdEncoding.EncodeToString(ct),
        base64.StdEncoding.EncodeToString(n), ver, nil
}

func (c *CryptoService) Decrypt(ctB64, nonceB64 string, ver int) (string, error) {
    key, ok := c.keys[ver]
    if !ok {
        return "", fmt.Errorf("unknown key version %d", ver)
    }
    ct, err := base64.StdEncoding.DecodeString(ctB64)
    if err != nil {
        return "", err
    }
    nonce, err := base64.StdEncoding.DecodeString(nonceB64)
    if err != nil {
        return "", err
    }
    block, err := aes.NewCipher(key)
    if err != nil {
        return "", err
    }
    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return "", err
    }
    pt, err := gcm.Open(nil, nonce, ct, nil)
    if err != nil {
        return "", fmt.Errorf("decrypt: %w (tampered?)", err)
    }
    return string(pt), nil
}
```

Provider 配置保存时加密，读取时解密（仅在内存中短暂存在）：

```go
func (s *ProviderService) SaveKey(ctx context.Context,
    provider, apiKey string) error {
    ct, nonce, ver, err := s.crypto.Encrypt(apiKey)
    if err != nil {
        return err
    }
    return s.repo.UpdateKey(ctx, provider, ct, nonce, ver)
}

func (s *ProviderService) GetDecryptedKey(ctx context.Context,
    provider string) (string, error) {
    cfg, err := s.repo.GetKey(ctx, provider)
    if err != nil {
        return "", err
    }
    return s.crypto.Decrypt(cfg.Ciphertext, cfg.Nonce, cfg.KeyVersion)
}
```

Python 引擎侧的 Mock client（DEMO_MODE）：

```python
import asyncio, random, time

class MockLLMClient:
    async def complete(self, *, provider, model=None,
                       system, user, temperature=0.7, tools=None):
        await asyncio.sleep(random.uniform(0.3, 0.9))
        if "identity" in system.lower() or "身份" in system:
            return "你是一位融合了多学科视角的思考者，擅长跨领域类比。"
        if "fuse" in system.lower() or "融合" in system:
            return (
                "# 身份\n你是一位融合型助手。\n\n"
                "# 原则\n- 先结构化拆解再回答\n- 用类比解释复杂概念\n"
            )
        return f"[DEMO] 收到你的问题（{len(user)} 字），这是模拟回答。"

    async def stream(self, *, provider, model=None,
                     system, user, temperature=0.7):
        full = await self.complete(
            provider=provider, system=system,
            user=user, temperature=temperature)
        for ch in full:
            await asyncio.sleep(0.02)
            yield {"content": ch, "tool_calls": None, "done": False}
        yield {"content": "", "tool_calls": None, "done": True}
```

引擎启动时按环境变量选 client：

```python
if settings.DEMO_MODE:
    llm_client = MockLLMClient()
else:
    llm_client = UnifiedLLMClient(key_provider=key_provider)
```

## 踩坑/权衡

**GCM 的 nonce 绝对不能复用**。同一密钥下 nonce 重复会彻底破坏安全性。我每次加密都用 `crypto/rand` 生成新 nonce 并随密文一起存，这是标准做法。别图省事儿用自增 ID 当 nonce。

**主密钥放环境变量就够安全吗**。对一个中小型开源项目，环境变量 + K8s Secret 是合理基线；更高安全等级应该上 KMS（云厂商的密钥管理服务），让应用永远拿不到原始主密钥，只调 KMS 的加解密接口。我在代码里预留了 `KeyProvider` 接口，本地用环境变量实现，生产可以替换成 KMS 实现，业务代码不用改。

**解密后的 Key 在内存里**。Go 的 string 不可清空，理论上可能留在内存。我在传完请求后不长期持有它，且 `httpx` 请求结束就释放引用。对极致安全场景可以用 `[]byte` 并在使用后清零，但 Go 标准库的 HTTP header 也是 string，收益有限，属于权衡。

**DEMO_MODE 不能只挡写不挡读**。最早我只在配置保存处判 demo 模式，结果对话接口照样拿不到 key 而报错。正确做法是在 LLMClient 这一层整体替换，业务逻辑无感知地走 Mock。同理，DEMO_MODE 下的数据库迁移和定时任务也要跳过，避免演示环境连生产资源。

**Mock 要足够"像"才能测前端**。如果 Mock 一秒返回大段文本，前端的流式打字效果、SSE 进度条、loading 状态根本测不到。所以 Mock 带随机延迟和逐 chunk 吐出，甚至对不同任务返回不同结构的假 prompt，让前端能完整走通融合进度、血统展示、对话沙箱。这对开源项目降低体验门槛很重要。

**别把测试环境的 demo key 提交到仓库**。我在 `.env.example` 里只留 `DEMO_MODE=true` 和占位符，CI 跑测试时用 demo 模式，不需要任何真实 Key。

## 小结

API Key 加密和 DEMO_MODE 看起来是两件事，本质上都是在"可控边界内运行不可信输入"：加密让数据库泄露不等于 Key 泄露，主密钥版本化让轮转可行；DEMO_MODE 让任何人都能安全体验产品而不碰真实额度，通过在适配层整体替换 LLMClient 实现业务无感知。安全设计不追求绝对，而是把风险分层、把接口留好，让默认配置就足够安全，更高需求可以平滑升级到 KMS。这是我从统一支付平台签名到统一认证中心密钥管理一路积累的习惯。
