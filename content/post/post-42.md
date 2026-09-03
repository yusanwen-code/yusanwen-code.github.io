---
title: "数据集管理服务架构设计"
slug: "post-42"
date: 2025-06-08T10:30:00+08:00
draft: false
image: /images/post-42-cover.jpg
tags: ["数据集", "架构", "S3"]
categories: ["架构"]
description: "Hertz + S3 + eino/pond 构建文档解析与知识图谱服务"
---

## 问题背景

某科技公司的 AI 数据平台需要一个统一的数据集管理服务，支撑学术文档上传、解析、向量化、知识图谱构建，并向知识库问答服务提供检索能力。数据形态多样：PDF、Word、图片、结构化表格；存储量大；处理链路长且耗资源。单体应用把上传、解析、检索混在一起会互相影响，也无法独立扩缩容。数据集管理服务就是在这个背景下设计的，我主导了它的后端架构。

## 方案设计

服务基于 Hertz（字节开源的 HTTP 框架）构建，按职责拆成几个模块：

- **API 层**：数据集 CRUD、文档上传、检索接口，用 Hertz 的路由分组和中间件做鉴权、日志、限流。
- **存储层**：原始文件存 S3 兼容对象存储（MinIO），元数据存 GaussDB，向量和图谱实体存 MongoDB（向量集合 + 图遍历）。
- **处理层**：eino 编排解析流水线，pond 控制并发（前两篇已讲）。
- **检索层**：向量检索 + 关键词检索混合召回，支持按数据集、文档、元数据过滤。

上传走 S3 预签名，前端直传对象存储，不经过服务带宽：

```go
func (h *DatasetHandler) PresignUpload(c context.Context, ctx *app.RequestContext) {
    var req UploadReq
    if err := ctx.BindAndValidate(&req); err != nil {
        ctx.JSON(400, errResp(err))
        return
    }
    key := fmt.Sprintf("datasets/%s/%s%s", req.DatasetID, snowflake.NextID(), extOf(req.Filename))
    url, err := h.s3.PresignPutObject(c, key, 15*time.Minute)
    if err != nil {
        ctx.JSON(500, errResp(err))
        return
    }
    ctx.JSON(200, map[string]any{"url": url, "object_key": key})
}
```

前端拿到预签名 URL 直传 S3，完成后回调服务，服务创建文档记录并投递解析任务。

处理链路用 Temporal 做任务编排（和数据治理服务共用 Temporal 集群），每个文档是一个 workflow，内部调 eino Chain 完成解析、分块、embedding、入图谱。Temporal 负责重试、超时和状态持久化，服务重启后任务不丢。

检索接口对知识库问答服务提供统一的 `Search`：

```go
type SearchService struct {
    vecStore VectorStore
    kwStore  KeywordStore
    graph    GraphStore
}

func (s *SearchService) Search(ctx context.Context, req *SearchReq) (*SearchResp, error) {
    // 1. 向量召回
    vecHits, err := s.vecStore.Search(ctx, req.DatasetID, req.QueryEmbedding, req.TopK)
    if err != nil {
        return nil, err
    }
    // 2. 关键词召回（BM25）
    kwHits, _ := s.kwStore.Search(ctx, req.DatasetID, req.Query, req.TopK)
    // 3. 融合排序（RRF）
    fused := rrfFuse(vecHits, kwHits)
    // 4. 图谱扩展：对 top 结果关联实体补充邻接信息
    enriched := s.graph.Expand(ctx, fused, req.DatasetID)
    return &SearchResp{Hits: enriched}, nil
}
```

依赖注入用 Wire，Service/DAO/Client 分层清晰：

```go
// wire.go
func NewDatasetService(
    cfg *Config,
    db *gorm.DB,
    mongo *mongo.Client,
    s3 *s3.Client,
    temporalClient client.Client,
    chain *eino.Chain,
) *DatasetService {
    // ...
}
```

## 踩坑与权衡

**上传和处理解耦**。最初想在上传接口里同步解析，大文件一上来接口就超时。改成预签名直传 + Temporal 异步任务后，接口只负责元数据和任务投递，处理能力可以独立扩容。文档状态用状态机管理（uploaded → parsing → parsed / failed），前端轮询或订阅进度。

**存储选型**。GaussDB 存结构化元数据（数据集、文档、权限），MongoDB 存向量和非结构化 chunk——主要是因为它的向量索引和文档模型适合 chunk + metadata 的形态。图谱没有引入独立图数据库，而是在 MongoDB 里用集合存实体和关系，对当前规模够用，避免了多一个中间件的运维成本；后续如果图遍历深度变大再考虑换专门的图库。

**大文件与小文件混合**。几百页的 PDF 解析耗内存，我们在 Temporal workflow 里按页拆分 activity，每页独立处理并落盘，避免一次性把整个文档加载进内存。小文件则批量合并处理，减少 workflow 调度开销。

**幂等与重试**。解析任务可能因 OOM 或节点重启被 Temporal 重试，所有写入都以文档 ID + chunk 序号做幂等键，重试不会产生重复向量。S3 上的中间结果（解析出的文本、表格）也缓存起来，重试时跳过已完成阶段。

**多租户隔离**。数据集属于某个 AppRole 团队，所有查询强制带租户过滤条件，S3 的 key 前缀也按租户隔离，预签名 URL 有时效，防止越权下载。

## 小结

数据集管理服务的核心思路是"上传走对象存储直传，处理走异步工作流，检索做多路召回"。Hertz 提供高性能 API 层，S3 承载原始文件，eino+pond 解决解析并发，Temporal 保证任务可靠，GaussDB+MongoDB 分别承接元数据和向量图谱。这套架构支撑了知识库问答服务的知识库问答，也为后续知识图谱和多模态检索留了扩展空间。

> 封面图：[motleypixel / Flickr](https://www.flickr.com/photos/16894864@N05/6239564720) · CC BY 2.0
