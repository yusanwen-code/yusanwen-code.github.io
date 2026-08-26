---
title: "eino 框架实战：高并发文档解析流水线"
date: 2025-05-07T10:30:00+08:00
draft: false
tags: ["eino", "并发", "文档解析"]
categories: ["AI"]
description: "用 eino 编排数据集管理服务的文档解析与向量化流水线"
---

## 问题背景

数据集管理服务要处理批量上传的学术文档（PDF/Word/图片），每份文档的链路是：下载 → 格式检测 → 解析抽取 → 清洗分块 → 向量化 → 入向量库。早期用串行的函数调用实现，一份 50 页的 PDF 全流程要几十秒；批量导入几百份时，单实例处理能力明显不够。直接起 goroutine 又难以控制并发度、做错误传递和阶段背压。

我们引入了字节开源的 eino 框架，用它的 Chain/Graph 编排能力把这条流水线重构成可并发、可观测的 DAG。

## 方案设计

eino 的核心抽象是 `Compose`，我们把每个处理阶段实现为一个可复用的组件，再串成 Chain。链路中能并行的阶段（如一份文档内多页并行解析、多 chunk 并行 embedding）用 `Graph` 扇出。

```go
// 组件签名示例：接收原始文档，输出解析后的结构化块
type Parser interface {
    Invoke(ctx context.Context, in *RawDoc, opts ...compose.Option) (*ParsedDoc, error)
}

type Chunker interface {
    Invoke(ctx context.Context, in *ParsedDoc, opts ...compose.Option) ([]*Chunk, error)
}

type Embedder interface {
    Invoke(ctx context.Context, in []*Chunk, opts ...compose.Option) ([]*VectorChunk, error)
}
```

构建 Chain：

```go
chain, err := compose.NewChain[*RawDoc, *VectorResult]().
    AppendLambda(compose.InvokableLambda(downloader.Fetch)).
    AppendLambda(compose.InvokableLambda(parser.Parse)).
    AppendLambda(compose.InvokableLambda(chunker.Split)).
    AppendLambda(compose.InvokableLambda(embedder.EmbedBatch)).
    AppendLambda(compose.InvokableLambda(writer.Upsert)).
    Build()
```

对单文档内的多页解析，我们用 Graph 做扇入扇出：解析器输出 `[]*Page` 后，按页分发到多个 worker 并行做 OCR/版面识别，再聚合。eino 支持用 `AddGraphNode` 和分支把这层拓扑显式表达出来，比手写 goroutine+WaitGroup 更清晰。

在批量入口，我们用 pond 作为外层 goroutine 池控制文档级并发（下一篇会细讲），每份文档内部交给 eino Chain 执行，形成"外层池 + 内层 DAG"的两层并发结构。

```go
func (s *Service) IngestBatch(ctx context.Context, docs []*RawDoc) error {
    group := pond.NewGroup(ctx)
    for _, d := range docs {
        d := d
        group.Submit(func() error {
            res, err := s.chain.Invoke(ctx, d)
            if err != nil {
                zap.L().Error("ingest failed", zap.String("key", d.ObjectKey), zap.Error(err))
                return err
            }
            zap.L().Info("ingest done", zap.Int("vectors", res.Count))
            return nil
        })
    }
    return group.Wait()
}
```

## 踩坑与权衡

**上下文透传**。eino 在节点间通过 `compose.Option` 传值，但我们需要在整条链路带上租户 ID、trace ID 做日志和链路追踪。做法是把这些值放进 `context.Context`，所有组件从 ctx 取，而不是塞进 Option 或入参结构体，避免污染组件签名。

**批大小与背压**。embedding 接口对批量大小有限制，一次塞太多会超 payload 或超时。我们在 Embedder 内部把 chunk 切成 micro-batch（比如每批 16 条），顺序调用，对上层仍是一个组件。如果上游解析太快、下游写库跟不上，eino 的 Channel 通信会自然产生背压，不会无限堆内存。

**部分失败的处理**。一份文档里某一页 OCR 失败，不应该让整份文档失败。我们在页级 fan-out 节点对错误做降级：失败页记录到 metadata 并跳过，成功页继续聚合。只有关键阶段（下载、入向量库）失败才让整份文档返回错误。

**组件要无状态**。Parser、Chunker 这些组件设计成无状态可复用的，配置（模型名、分块大小）在构造时注入，运行时只读。这样同一个 Chain 实例可以被多个 goroutine 并发调用，不需要每次请求重建。

**可观测性**。eino 支持 callback，我们注册了全局 callback，在每个节点开始/结束时打点，配合 Jaeger 把一次文档处理的各阶段耗时串成一条 trace，定位瓶颈非常直观——通常最慢的是 OCR 和 embedding。

## 小结

eino 帮我们把文档处理从一串耦合的函数调用变成了显式的、可并发的流水线。组件化后每个阶段都能独立替换和测试；Graph 的扇入扇出让页级并行写起来很干净。数据集管理服务用 eino 编排解析、用 pond 控制批量并发，两层配合后批量导入的吞吐比早期串行实现有数量级提升，代码可读性反而更好。
