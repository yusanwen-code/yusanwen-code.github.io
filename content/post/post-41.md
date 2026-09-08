---
title: "基于 pond 的 goroutine 池在文档向量化中的应用"
slug: "post-41"
date: 2025-05-23T10:30:00+08:00
draft: false
image: /images/post-41-cover.jpg
tags: ["pond", "goroutine池", "向量化"]
categories: ["Go"]
description: "用 pond 限制并发、收集错误，平稳跑大批量向量化任务"
---

## 一个 for 循环，几千个 goroutine

数据集管理服务里，一个数据集可能有上千份文档，每份文档切出几十到上百个 chunk，每个 chunk 都要调一次 embedding 接口。最朴素的写法是 for 循环里直接 `go func()`。结果可以想象：几千个 goroutine 同时打向远程 embedding 服务，对方 QPS 瞬间被打满，自己内存也跟着暴涨，错误没法统一收集，想取消也停不下来。

我们需要的就是一个有上限、能等结果、能感知 context 取消的池。手写 worker channel 试过，`errgroup` 也试过，最后在数据集管理服务里用了 pond（`github.com/alitto/pond`）。倒不是它有什么魔法，主要是 API 简洁，池大小、任务队列、等待、错误聚合都内置了。

## 两级并发，两个池

向量化天然是两级并发：文档级和 chunk 级。我们干脆用两个 pond 池隔离开，免得两层的 goroutine 互相争抢。

![两级 goroutine 池：文档级与 chunk 级隔离，容量跟着下游 embedding 配额走](/images/post-41-pond-two-level.svg)

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

单文档内的 chunk 向量化，用 pond 的 `Submit` 分发，`Wait` 等所有 chunk 干完：

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

批量处理文档时，外层由 `docPool` 控并发，每份文档内部再用 `chunkPool`。两层池的容量按下游 embedding 服务的限流配额来定：chunk 池大小不超过服务允许的并发数，从源头就不给它触发限流的机会。

需要有序结果的场景，按索引写 `results[i]`。goroutine 谁先跑完无所谓，最终切片照样和输入对齐。

## 六个坑

先说 panic。pond 默认会 recover 任务里的 panic，进程不会挂，但有个副作用：panic 信息容易被吞。所以每个任务里我们又加了一层自己的 recover，把 stack 记到 Zap 日志，空指针这类问题才有得查。

容量别跟 CPU 核数挂钩。embedding 是 IO 密集型，goroutine 大部分时间在等网络，池大小应该按下游配额和 P95 延迟算，照着 `runtime.NumCPU()` 定没有道理。我们用 32，是因为 embedding 服务单 key 的并发上限大概就在这个量级。

context 一定要传进去。批量任务跑到一半，用户取消了或者某个文档失败了，剩下的任务得能停下来。pond v2 的 `Group` 支持绑定 context，取消后没开始的任务不再执行；正在跑的任务靠我们传进去的 ctx 感知取消，对应的 HTTP 请求也会中断。

错误这块我们改过一版。早期只返回 firstErr，结果一批里有几十个 chunk 失败，日志里只看得见一个错误，排查时误以为是个例。现在失败计数和前几条错误摘要都进日志，监控上对着失败比例告警。

还有个 Go 的经典老坑：闭包捕获循环变量。results 切片在 Submit 前一次性分配好，这个做法本身没问题；但 Go 1.22 之前循环变量会被复用，goroutine 里必须 `i, c := i, c` 拷贝一份。

最后是池的生命周期。`Vectorizer` 在服务启动时创建、关闭时 `pool.Stop().Wait()` 停掉。别每个请求都 `pond.New`，建池有开销，复用的意义也就没了。

## 回头看

向量化是典型的高并发 IO 场景，关键不在"起更多 goroutine"，而在把并发数压到下游能承受的范围内。pond 用很小的 API 成本提供了池化、等待、错误聚合和 context 取消，比手写 channel 加 WaitGroup 省心。数据集管理服务用的就是文档级、chunk 级两个池，吞吐保住了，embedding 服务也没被打垮。

> 封面图：[gliak00 / Flickr](https://www.flickr.com/photos/126219266@N06/30083358625) · CC BY-SA 2.0
