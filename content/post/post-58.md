---
title: "Go 网关 + Python 合成引擎 + Next.js 三段式架构实践"
slug: "post-58"
date: 2026-02-13T10:30:00+08:00
draft: false
tags: ["Go", "FastAPI", "Next.js"]
categories: ["架构"]
description: "alchemy-furnace 为什么用三段式架构，以及它们之间如何协作"
---

## 问题背景

alchemy-furnace 立项时，我面对一个典型矛盾：我是 Go 主力，后端那一套（Gin、GORM、Wire、并发模型）写得最顺；但炼丹的核心——提示词变异算子、多供应商 LLM 适配、后续可能接的 agent 编排——Python 生态明显更快。前端我又希望用 Next.js 做一个交互流畅的控制台，而不是套模板。

如果全用一种语言，要么牺牲迭代速度（Go 手搓 prompt 实验），要么牺牲工程稳定性（Python 扛业务网关和并发）。所以我从一开始就定了三段式：Go 网关、Python 合成引擎、Next.js 前端。这篇讲它们之间怎么切、怎么连、踩了哪些坑。

## 方案/设计

职责切分遵循一个原则：**稳定的、要强类型和高并发的归 Go；易变的、AI 实验性强的归 Python；交互和渲染归 Next.js。**

- **Go 网关（gateway）**：用户认证、API Key 管理、金丹/任务/产物的 CRUD、计费配额、请求签名、SSE 进度推送、对 Python 引擎的调用与降级。Gin + GORM + Wire，MySQL 存元数据，Redis 做任务队列和缓存。
- **Python 合成引擎（furnace-engine）**：融合算子（crossover/mutate/ensemble）、多供应商 LLM 适配层、提示词缓存、血统计算。FastAPI + httpx，无状态，水平扩展靠 K8s 加副本。
- **Next.js 前端（console）**：金丹编辑器、炼丹任务向导、分身对话沙箱、血统图谱可视化。App Router + SSE 消费网关进度。

三段之间的调用链：

```
Browser ──HTTP/SSE──> Go Gateway ──HTTP+签名──> Python Engine
                            │
                            └──> MySQL / Redis / S3
```

Python 引擎不直接暴露给浏览器，也不直连业务库——它只接收网关签名过的任务请求，必要时从 S3 读写大对象。这样安全边界清晰，引擎挂了不影响用户登录和数据查询，网关还能返回降级结果。

## 关键代码

Go 调 Python 这一层我封了一个 client，带超时、重试和签名。签名用 HMAC-SHA256，避免引擎被内网其他服务误调：

```go
type FurnaceClient struct {
    cli        *http.Client
    baseURL    string
    signSecret string
}

func (c *FurnaceClient) Submit(ctx context.Context, job FurnaceJob) (*FurnaceAck, error) {
    body, _ := json.Marshal(job)
    req, _ := http.NewRequestWithContext(ctx, "POST",
        c.baseURL+"/v1/furnace/fuse", bytes.NewReader(body))
    req.Header.Set("Content-Type", "application/json")
    ts := strconv.FormatInt(time.Now().Unix(), 10)
    req.Header.Set("X-Furnace-Ts", ts)
    req.Header.Set("X-Furnace-Sign",
        c.sign(body, ts)) // HMAC-SHA256(secret, ts+body)

    resp, err := c.cli.Do(req)
    if err != nil {
        return nil, fmt.Errorf("furnace call: %w", err)
    }
    defer resp.Body.Close()
    if resp.StatusCode >= 500 {
        return nil, ErrFurnaceUnavailable // 网关层触发降级
    }
    var ack FurnaceAck
    json.NewDecoder(resp.Body).Decode(&ack)
    return &ack, nil
}
```

Python 侧用一个轻量依赖校验签名：

```python
from fastapi import Request, HTTPException
import hmac, hashlib, time

async def verify_signature(request: Request):
    secret = settings.FURNACE_SIGN_SECRET
    ts = request.headers.get("X-Furnace-Ts", "")
    sign = request.headers.get("X-Furnace-Sign", "")
    body = await request.body()
    expected = hmac.new(
        secret.encode(),
        (ts.encode() + body),
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(expected, sign):
        raise HTTPException(status_code=401, detail="bad signature")
    if abs(time.time() - int(ts)) > 300:
        raise HTTPException(status_code=401, detail="stale timestamp")
```

前端的进度条走 SSE，网关把 Python 引擎的阶段事件透传成统一格式：

```ts
// Next.js 客户端
const evt = new EventSource(`/api/fusion/${jobId}/stream`);
evt.onmessage = (e) => {
  const { stage, message } = JSON.parse(e.data);
  setStages((s) => [...s, { stage, message }]);
  if (stage === "done" || stage === "failed") evt.close();
};
```

## 踩坑/权衡

**同步还是异步**是第一个抉择。融合任务要调 LLM，耗时几秒到几十秒。我没有让网关同步阻塞等引擎，而是引擎返回 `job_id`，网关写任务表，引擎通过回调 + SSE 推进度。好处是网关不被长连接拖垮，坏处是多了一套任务状态机。我用 Redis 存中间态、MySQL 存终态，状态流转集中在 Go 侧，Python 只发事件不直接改库。

**Python 无状态但要缓存**。合成提示词缓存（后面单篇讲）我放在 Redis 里，引擎实例不持有本地状态，这样 K8s 滚动更新和扩缩容都安全。代价是每次要多一次网络往返，但相比一次 LLM 调用，这个开销可以忽略。

**CORS 和 Cookie** 也坑过。Next.js 开发时直连 Go 网关会跨域，我没有放开 CORS 让浏览器直连，而是在 Next.js 里用 Route Handler 做反向代理，同源访问，Cookie 和 SSE 都干净。生产上则由 KubeSphere 的网关统一路由。

**要不要上 gRPC**？我考虑过。但引擎接口变化快、字段常加，HTTP+JSON 在这个阶段调试成本最低，pydantic 做校验也够用。等接口稳定、QPS 真上来了，再把内部高频调用换成 gRPC 不迟。我在某 SaaS 公司做过 fasthttp 到 go-zero 的迁移，深知过早引入复杂 RPC 的代价。

## 小结

三段式不是为了炫技，而是让每种语言做它最擅长的事：Go 守住稳定和并发的底线，Python 承接 AI 的快速迭代，Next.js 提供交互体验。边界靠"Python 不直连业务库、所有内部调用带签名、任务状态归 Go 管"这三条约束来保证清晰。这套结构让我能一个人独立完成全栈交付，又不至于让任何一层变成难以维护的大泥球。
