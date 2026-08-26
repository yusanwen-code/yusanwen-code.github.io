---
title: "基于 pond 的 goroutine 池在文档向量化中的应用"
slug: "post-41"
date: 2025-05-23T10:30:00+08:00
draft: false
tags: ["pond", "goroutine池", "向量化"]
categories: ["Go"]
description: "用 pond 限制并发、收集错误，平稳跑大批量向量化任务"
---

## 问题背景

数据集管理服务里一个数据集可能有上千份文档，每份文档切分出几十到上百个 chunk，每个 chunk 都要调一次 embedding 接口。最朴素的写法是 for 循环里直接 `go func()`，结果是几千个 goroutine 同时调远程 embedding 服务：瞬间把对方 QPS 打满、自己内存暴涨、还没法统一收集错误和控制取消。

我们需要的是一个有上限、能等结果、能感知 context 取消的 goroutine 池。试过手写 worker channel，也试过 `errgroup`，最后在数据集管理服务里选了 pond（`github.com/alitto/pond`），它的 API 简洁，内置池大小、任务队列、等待和错误聚合。

## 方案设计

向量化场景是两级并发：文档级并发和 chunk 级并发。我们用两个 pond 池隔离，避免文档级和 chunk 级 goroutine 互相争抢。

```go
type Vectorizer struct {
    docPool   *pond.Pool   // 文档级，控制同时处理的文档数
    chunkPool *pond.Pool   // chunk 级，控制 embedding 并发
    client    EmbeddingClient
}

func NewVectorizer(client EmbeddingClient) *Vectorizer {
    return &Vectorizer{
        // 文档级并发较低，主要受 IO 和内存限制
        docPool: pond.New(8, 1000),
        // chunk 级并发受 embedding 服务 QPS 限制
        chunkPool: pond.New(32, 5000),
        client:    client,
    }
}
```

单文档内的 chunk 向量化用 pond 的 `Submit` 分发，用 `Wait` 等所有 chunk 完成：

```go
func (v *Vectorizer) embedChunks(ctx context.Context, chunks []*Chunk) ([]*VectorChunk, error) {
    results := make([]*VectorChunk, len(chunks))
    var firstErr error
    var mu sync.Mutex

    group := pool.Group()
    for i, c := range chunks {
        i, c := i, c
        group.Submit(func() {
            vec, err := v.client.Embed(ctx, c.Text)
            if err != nil {
                mu.Lock()
                if firstErr == nil {
                    firstErr = err
                }
                mu.Unlock()
                return
            }
            results[i] = &VectorChunk{Chunk: c, Vector: vec}
        })
    }
    group.Wait()
    return results, firstErr
}
```

批量文档处理时，外层用 `docPool` 控制并发，每份文档内部再用 `chunkPool`。两层池的容量根据下游 embedding 服务的限流配额设置——chunk 池大小不超过服务允许的并发数，从源头避免触发限流。

对于需要有序结果的场景，我们按索引写入 `results[i]`，这样即使 goroutine 乱序完成，最终切片仍然和输入对齐。

## 踩坑与权衡

**panic 会被池 recover**。pond 默认 recover 任务里的 panic，不会让整个进程挂掉，但 panic 信息容易被吞。我们在每个任务里加了自己的 recover，把 stack 记到 Zap 日志，方便排查空指针等问题。

**不要把池容量设成和 CPU 核数挂钩**。embedding 是 IO 密集型任务，goroutine 大部分时间在等网络，池大小应该按下游配额和 P95 延迟算，而不是 `runtime.NumCPU()`。我们用 32 是因为 embedding 服务单 key 并发上限大概在这个量级。

**context 取消要传进去**。批量任务中如果用户取消或某个文档失败，要及时停下剩余任务。pond v2 的 `Group` 支持绑定 context，context 取消后未开始的任务不再执行；正在跑的任务通过我们传入的 ctx 感知到取消，HTTP 请求也会随之中断。

**错误只记第一个，但要统计失败数**。早期我们只返回 firstErr，结果一批里有几十个 chunk 失败却只看到一个错误，排查时误以为是个例。现在把失败计数和前几个错误摘要都记到日志，监控里对失败比例告警。

**注意结果切片的内存占用**。上千个 chunk 同时 embedding 时，results 切片在 Submit 前就分配好，这没问题；但要避免在 goroutine 里闭包捕获循环变量——这是经典坑，Go 1.22 前循环变量会被复用，必须用 `i, c := i, c` 拷贝一份。

**池的生命周期**。`Vectorizer` 在服务启动时创建、关闭时停止（`pool.Stop().Wait()`），不要每次请求都 `pond.New`，否则建池开销和失去复用意义。

## 小结

向量化是典型的高并发 IO 场景，关键不是"起更多 goroutine"，而是"把并发数控制在下游能承受的范围内"。pond 用很小的 API 成本提供了池化、等待、错误聚合和 context 取消，比手写 channel+WaitGroup 省心。数据集管理服务用文档级和 chunk 级两个池，既保证了吞吐，又不会把 embedding 服务打垮。
