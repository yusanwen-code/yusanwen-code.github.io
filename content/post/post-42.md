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

## 为什么不做成单体

某科技公司的 AI 数据平台需要一个统一的数据集管理服务：往上支撑学术文档上传、解析、向量化、知识图谱构建，往下给知识库问答服务供检索能力。数据形态从 PDF、Word 到图片、结构化表格都有，存储量大，处理链路又长又耗资源。

之所以不做成单体，是因为上传、解析、检索混在一个进程里会互相影响，任何一边都没法独立扩缩容。数据集管理服务就是照着这个约束设计的，后端架构由我主导。

## 整体怎么拆

服务基于 Hertz（字节开源的 HTTP 框架）搭，按职责拆成几块。API 层管数据集 CRUD、文档上传、检索接口，用 Hertz 的路由分组和中间件做鉴权、日志、限流。存储层分三份：原始文件放 S3 兼容对象存储（MinIO），元数据存 GaussDB，向量和图谱实体存 MongoDB，向量一个集合，图遍历也靠它。处理层用 eino 编排解析流水线，并发交给 pond，前两篇已经讲过。检索层做向量加关键词的混合召回，支持按数据集、文档、元数据过滤。

![数据集管理服务整体架构：上传直传、Temporal 异步处理、混合检索三条链路](/images/post-42-dataset-architecture.svg)

模块间的依赖注入用 Wire，Service/DAO/Client 各归各层：

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

## 上传直传，解析异步

上传走 S3 预签名，前端直传对象存储，不占用服务带宽：

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

前端拿到预签名 URL 直传 S3，传完回调服务，服务创建文档记录、投递解析任务。

处理链路交给 Temporal 编排（和数据治理服务共用一个 Temporal 集群），每个文档一个 workflow，内部调 eino Chain 走完解析、分块、embedding、写图谱。重试、超时、状态持久化都是 Temporal 的活，服务重启任务也不丢。

## 检索是多路召回

检索接口对知识库问答服务只暴露一个统一的 `Search`：

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

## 五个关键取舍

上传和处理必须拆开。最初想在上传接口里同步解析，大文件一进来接口就超时。改成预签名直传加 Temporal 异步任务之后，接口只管元数据和任务投递，处理能力想扩就单独扩。文档状态用状态机管理（uploaded → parsing → parsed / failed），前端轮询或订阅进度。

存储选型上，GaussDB 存结构化元数据（数据集、文档、权限），MongoDB 存向量和非结构化 chunk，主要看中它的向量索引和文档模型，跟 chunk 加 metadata 的形态正合适。图谱没有引入独立图数据库，实体和关系就用 MongoDB 集合存，当前规模够用，还省掉一个中间件的运维成本；等图遍历深度真上去了，再换专门的图库不迟。

大文件和小文件分开对待。几百页的 PDF 解析起来很吃内存，我们在 Temporal workflow 里按页拆 activity，每页独立处理、独立落盘，避免整个文档一口气读进内存。小文件反过来，批量合并处理，省 workflow 调度开销。

幂等和重试要提前想好。解析任务可能因为 OOM 或节点重启被 Temporal 重试，所有写入都以文档 ID 加 chunk 序号做幂等键，重试不会产生重复向量。S3 上的中间结果（解析出的文本、表格）也缓存着，重试时已完成的阶段直接跳过。

多租户隔离贯穿全链路。数据集属于某个 AppRole 团队，所有查询强制带租户过滤条件，S3 的 key 前缀也按租户隔离，预签名 URL 带时效，防越权下载。

## 三条链路各走各的

整个服务拆开看就三件事：上传走对象存储直传，处理走异步工作流，检索做多路召回。Hertz 顶在 API 层，S3 承载原始文件，eino 加 pond 解决解析并发，Temporal 保证任务可靠，GaussDB 和 MongoDB 分别承接元数据和向量图谱。这套架构支撑着知识库问答服务，也给后续的知识图谱和多模态检索留了扩展空间。

> 封面图：[motleypixel / Flickr](https://www.flickr.com/photos/16894864@N05/6239564720) · CC BY 2.0
