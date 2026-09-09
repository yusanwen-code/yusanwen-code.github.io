---
title: "知识库检索召回优化：从关键词到向量混合检索"
slug: "post-35"
date: 2025-02-18T10:30:00+08:00
draft: false
image: /images/post-35-cover.jpg
tags: ["检索","向量检索","混合检索"]
categories: ["AI"]
description: "BM25 与向量检索融合提升召回率的实践"
---

## 搜错误码，向量检索掉了链子

知识库问答上线初期，纯向量检索的问题很快露出来了。用户搜产品编号、错误码、人名、专业术语的时候，向量模型经常"理解"偏，返回一堆语义相近、关键词却对不上的文档；反过来，用户用口语化描述问题时，关键词检索又因为字面不匹配漏掉相关文档。

最典型的一个例子：用户搜"ERR_CONN_RESET"，向量检索返回了一堆讲"网络连接问题"的通用文档，真正包含这个错误码的排查手册反而排在后面。精确匹配这件事，向量检索天然干不过关键词检索。

所以我们需要混合检索：把 BM25 关键词检索和向量检索的结果融合起来，取长补短。

## 三步：双路召回、融合、精排

1. 双路召回：同时执行 BM25 关键词检索和向量相似度检索，各自返回 TopN；
2. 分数归一化与融合：两路分数分布不同，BM25 无上界，向量余弦在 0 到 1 之间，得归一化后用 RRF（Reciprocal Rank Fusion）或加权求和来排；
3. 重排序：融合后的候选集（通常 20 到 30 条）用 Cross-Encoder 重排序模型精排，取 Top5 作为最终上下文。

选型没什么可犹豫的：BM25 用 Elasticsearch，我们本来就有 ES 集群；向量用 Qdrant；Rerank 用 bge-reranker-v2-m3 本地部署。

![混合检索：双路召回、RRF 融合、Rerank 精排](/images/post-35-hybrid-retrieval.svg)

## 双路召回，谁挂了用谁

两路检索并行跑，互不拖累，任一路失败不阻断，降级用另一路的结果：

```go
type RetrievalResult struct {
    DocID    string
    Content  string
    Score    float64
    Source   string // "bm25" or "vector"
    Metadata map[string]interface{}
}

func (s *HybridRetriever) Retrieve(ctx context.Context, query string, topK int) ([]RetrievalResult, error) {
    // 并行执行两路检索
    var (
        bm25Results    []RetrievalResult
        vectorResults  []RetrievalResult
        bm25Err        error
        vecErr         error
    )

    var wg sync.WaitGroup
    wg.Add(2)

    go func() {
        defer wg.Done()
        bm25Results, bm25Err = s.esClient.Search(ctx, query, topK*2)
    }()

    go func() {
        defer wg.Done()
        vectorResults, vecErr = s.qdrantClient.SearchByEmbedding(ctx, query, topK*2)
    }()

    wg.Wait()

    // 任一路失败不阻断，降级用另一路
    if bm25Err != nil {
        s.log.Warn("bm25 failed, using vector only", zap.Error(bm25Err))
        return vectorResults, vecErr
    }
    if vecErr != nil {
        s.log.Warn("vector search failed, using bm25 only", zap.Error(vecErr))
        return bm25Results, nil
    }

    // RRF 融合
    fused := rrfFusion(bm25Results, vectorResults, 60)
    if len(fused) > topK*2 {
        fused = fused[:topK*2]
    }

    // Rerank 精排
    reranked, err := s.reranker.Rerank(ctx, query, fused)
    if err != nil {
        s.log.Warn("rerank failed, using fused order", zap.Error(err))
        if len(fused) > topK {
            fused = fused[:topK]
        }
        return fused, nil
    }
    if len(reranked) > topK {
        reranked = reranked[:topK]
    }
    return reranked, nil
}
```

## RRF：只看排名，不看分数

融合是整个方案里最关键的一步。加权融合要调权重，RRF 干脆绕开原始分数，只看每一路的排名：

```go
// rrfFusion 基于倒数排名融合，k 为平滑常数（通常 60）
func rrfFusion(bm25, vector []RetrievalResult, k int) []RetrievalResult {
    scores := make(map[string]float64)
    resultMap := make(map[string]RetrievalResult)

    addRank := func(results []RetrievalResult) {
        for rank, r := range results {
            scores[r.DocID] += 1.0 / float64(k+rank+1)
            if _, exists := resultMap[r.DocID]; !exists {
                resultMap[r.DocID] = r
            }
        }
    }

    addRank(bm25)
    addRank(vector)

    var fused []RetrievalResult
    for docID, score := range scores {
        r := resultMap[docID]
        r.Score = score
        fused = append(fused, r)
    }

    sort.Slice(fused, func(i, j int) bool {
        return fused[i].Score > fused[j].Score
    })
    return fused
}
```

每路结果按排名取倒数再相加，k=60 做平滑。两路都靠前的文档，加出来的分数自然最高，不需要任何调参。

## Rerank 收尾

融合排序还是粗排，最后一道交给 Cross-Encoder 精排：

```go
type RerankerClient struct {
    baseURL string
    client  *http.Client
}

type RerankRequest struct {
    Query string   `json:"query"`
    Docs  []string `json:"documents"`
    TopN  int      `json:"top_n"`
}

type RerankResponse struct {
    Results []struct {
        Index          int     `json:"index"`
        RelevanceScore float64 `json:"relevance_score"`
    } `json:"results"`
}

func (c *RerankerClient) Rerank(ctx context.Context, query string, docs []RetrievalResult) ([]RetrievalResult, error) {
    var texts []string
    for _, d := range docs {
        texts = append(texts, d.Content)
    }

    body, _ := json.Marshal(RerankRequest{Query: query, Docs: texts, TopN: len(texts)})
    req, _ := http.NewRequestWithContext(ctx, "POST", c.baseURL+"/rerank", bytes.NewReader(body))
    req.Header.Set("Content-Type", "application/json")

    resp, err := c.client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var result RerankResponse
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }

    reranked := make([]RetrievalResult, len(result.Results))
    for i, item := range result.Results {
        reranked[i] = docs[item.Index]
        reranked[i].Score = item.RelevanceScore
    }
    return reranked, nil
}
```

ES 那边的 BM25 查询，title 加权，IK 分词：

```json
{
  "query": {
    "multi_match": {
      "query": "ERR_CONN_RESET",
      "fields": ["title^2", "content"],
      "type": "best_fields",
      "analyzer": "ik_max_word"
    }
  },
  "size": 20
}
```

## 调优的五个细节

中文分词是第一个要处理的。ES 默认的标准分词器对中文按字切分，搜"支付订单"可能匹配到"订单支付"，语义却丢了。换成 IK 分词器，索引用 `ik_max_word`、查询用 `ik_smart`，召回率明显提升。专业术语还得配自定义词典。

融合方案上我们对比过 RRF 和加权求和。加权融合要调权重，而且不同查询的最优权重不一样：精确查询该把 BM25 权重调高，语义查询该偏向向量这边。RRF 不依赖原始分数，不用调参，实际效果稳定，最后选了它。

Rerank 是延迟大头。Cross-Encoder 比向量检索慢一个数量级，单条约 10 到 30 毫秒，30 条批量要 200 到 500 毫秒。我们对候选集做了截断，只取融合后 Top30 进精排；实时对话这类延迟敏感的场景，Rerank 设 800 毫秒超时，超时就用融合排序兜底。

Embedding 模型也换过一版。之前用的英文预训练模型对中文召回一般，换成 `bge-large-zh-v1.5` 后，中文语义检索质量大幅提升。维度从 768 涨到 1024，Qdrant 的内存和索引时间有所增加，还在可接受范围内。

切分粒度是最后一个要较真的。chunk 太大，检索粒度粗、上下文噪声多；太小又丢完整语义。最后用的是 500 字加 50 字重叠的切分策略，表格和代码块单独保留，不切。

## 上线之后

首条命中率，也就是用户认为第一条就是答案的比例，从纯向量检索的约 60% 提到了 80% 以上，错误码、编号、人名这类查询改善最明显。

回头看，混合检索不是把两路结果拼在一起就完事，功夫在融合和精排这两个环节：BM25 管精确匹配，向量管语义理解，RRF 让两路结果公平合并，Rerank 再做最后一道精细排序。

> 封面图：[luis perez / Flickr](https://www.flickr.com/photos/65092670@N00/3879235872) · CC BY 2.0
