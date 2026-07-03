---
title: "Go 与 Python 混部：gRPC 还是 HTTP？我的选型权衡"
date: 2026-07-03T10:30:00+08:00
draft: false
tags: ["Go","Python","gRPC"]
categories: ["架构"]
description: "在 数据集管理服务 和 alchemy-furnace 中，Go 与 Python 混部的通信选型。"
---

## 问题背景

AI 应用里 Go 和 Python 混部几乎是常态：Go 写网关、并发调度、业务 API，Python 写模型推理、向量计算、文档解析。我在 数据集管理服务 里用 Go（Hertz）做接入和任务分发，用 eino + pond 跑高并发文档解析和向量化；在 alchemy-furnace 里是 Go（Gin + GORM）做网关，Python（FastAPI）做合成引擎。两边怎么通信，是每次都要回答的问题。

常见选项就三个：gRPC、HTTP/JSON、消息队列。MQ 用于异步解耦没争议，争议主要在同步调用选 gRPC 还是 HTTP。

## 方案与设计

我做过两版，结论是按场景分：

**内部高频、强类型、对延迟敏感 → gRPC。** 数据集管理服务 里 Go 调度器把文档分片发给 Python worker 池，单批上百个分片，每个分片要回传结构化的解析结果（段落、表格、向量）。这种场景 gRPC 的优势很明显：Protocol Buffers 契约明确，流式传输支持分片回传，连接多路复用省掉反复握手。

```protobuf
service ParserService {
  rpc Parse(stream ParseChunk) returns (stream ParseResult);
}

message ParseChunk {
  string doc_id = 1;
  bytes  content = 2;
  int32  chunk_index = 3;
}

message ParseResult {
  string doc_id = 1;
  int32  chunk_index = 2;
  repeated Paragraph paragraphs = 3;
  repeated Table tables = 4;
  repeated float embedding = 5;
}
```

Go 侧用 `google.golang.org/grpc` 起长连接，Python 侧用 `grpcio` 实现 Servicer，双向流让 worker 可以边解析边回传，不用等整批。

**跨边界、低频、需要调试和缓存 → HTTP/JSON。** alchemy-furnace 的 Go 网关调 Python 合成引擎，我用的是 HTTP。原因有三：一是合成请求本身耗时较长（要调多个 LLM 供应商），gRPC 的流式优势不明显；二是开发期用 curl/Postman 直接调试 HTTP 方便太多；三是网关前面还有 Nginx，HTTP 路径的超时、重试、日志都更成熟。

```go
// alchemy-furnace 网关调用 Python 合成引擎
type FusionRequest struct {
    SkillIDs  []string `json:"skill_ids"`
    Strategy  string   `json:"strategy"`
    Model     string   `json:"model"`
}

func (c *FusionClient) Fuse(ctx context.Context, req *FusionRequest) (*FusionResult, error) {
    body, _ := json.Marshal(req)
    httpReq, _ := http.NewRequestWithContext(ctx, "POST", c.baseURL+"/fuse", bytes.NewReader(body))
    httpReq.Header.Set("Content-Type", "application/json")
    resp, err := c.hc.Do(httpReq)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    var out FusionResult
    if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
        return nil, err
    }
    return &out, nil
}
```

## 踩坑与权衡

**第一，gRPC 的 Python 侧性能没那么神。** Python 受 GIL 限制，gRPC 的同步 Servicer 吞吐一般，要用 `grpc.aio` 异步实现 + 多进程 worker 才能打满。Go 调 Python 时，瓶颈往往在 Python 这边的 CPU，协议开销反而是小头。数据集管理服务 里我们靠 pond 在 Go 侧控制并发度，配合多个 Python 进程横向扩容。

**第二，gRPC 调试成本真实存在。** 链路追踪、错误码、payload 查看都比 HTTP 麻烦，KubeSphere 里抓包也不直观。我的做法是内部 gRPC 服务默认开启 reflection，开发期用 grpcurl 调试；生产环境必须接 Jaeger，把每次调用的方法、状态、耗时打到 trace 里。

**第三，版本兼容要守纪律。** Protobuf 字段只能加不能改类型、不能复用 tag，这条比 JSON 严格得多。我在 CI 里加了 `buf breaking` 检查，防止有人图省事改字段导致老客户端解析错乱。

**第四，流式场景 gRPC 优势明显。** 数据集管理服务 里解析一个大文档要几十秒，如果用 HTTP 轮询或长连接收 JSON，连接管理和超时都很别扭；gRPC 双向流天然适合这种"请求一次、结果分批回"的场景。

## 小结

我的选型原则很简单：内部高并发 + 结构化 + 流式用 gRPC；跨边界、低频、强调试便利性用 HTTP。别为了"显得先进"在所有地方都上 gRPC，也别为了省事在高频内部链路上用 JSON 硬扛。协议是手段，把瓶颈和团队维护成本算清楚，答案自然就出来了。
