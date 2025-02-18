---
title: "知识库检索召回优化：从关键词到向量混合检索"
date: 2025-02-18T10:30:00+08:00
draft: false
tags: ["检索","向量检索","混合检索"]
categories: ["AI"]
description: "BM25 与向量检索融合提升召回率的实践"
---

## 问题背景

知识库问答服务 的知识库问答上线初期，纯向量检索暴露了不少问题。用户搜产品编号、错误码、人名、专业术语时，向量模型经常"理解"偏差，返回语义相近但关键词不匹配的文档；反过来，用户用口语化描述问题时，关键词检索又因为词不匹配而漏掉相关文档。

最典型的例子：用户搜"ERR_CONN_RESET"，向量检索返回了一堆关于"网络连接问题"的通用文档，但真正包含这个错误码的排查手册反而排在后面。纯向量检索在精确匹配场景下天然不如关键词检索。

我们需要一套混合检索方案，把关键词检索（BM25）和向量检索的结果融合，取长补短。

## 方案设计

整体分为三步：

1. **双路召回**：同时执行 BM25 关键词检索和向量相似度检索，各自返回 TopN 结果。
2. **分数归一化与融合**：两路分数分布不同（BM25 无上界，向量余弦在 0-1），需要归一化后用 RRF（Reciprocal Rank Fusion）或加权求和排序。
3. **重排序（Rerank）**：融合后的候选集（通常 20-30 条）用 Cross-Encoder 重排序模型精排，取 Top5 作为最终上下文。

BM25 用 Elasticsearch（我们已有 ES 集群），向量用 Qdrant，Rerank 用 bge-reranker-v2-m3 本地部署。

## 关键代码

双路召回：

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

RRF 融合算法（不依赖原始分数，只看排名，对分数分布差异鲁棒）：

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

Reranker 调用：

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

ES 的 BM25 查询配置：

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

## 踩坑与权衡

- **中文分词**：ES 默认的标准分词器对中文按字切分，搜"支付订单"可能匹配到"订单支付"但漏了语义。我们换成 IK 分词器（`ik_max_word` 索引、`ik_smart` 查询），召回率明显提升。专业术语还需要自定义词典。
- **RRF vs 加权融合**：加权融合需要调权重，而且不同查询的最优权重不同（精确查询 BM25 权重应高，语义查询向量权重应高）。RRF 不依赖原始分数，无需调参，实际效果稳定，我们最终选了 RRF。
- **Rerank 延迟**：Cross-Encoder 比向量检索慢一个数量级（单条约 10-30ms，30 条批量约 200-500ms）。我们对候选集做了截断，只取融合后 Top30 进 Rerank。对延迟敏感的场景（如实时对话），Rerank 设了 800ms 超时，超时就用融合排序兜底。
- **Embedding 模型选择**：之前用的英文预训练模型对中文召回一般，换成 `bge-large-zh-v1.5` 后中文语义检索质量大幅提升。Embedding 维度从 768 增加到 1024，Qdrant 内存和索引时间有所增加，但在可接受范围内。
- **文档切分粒度**：chunk 太大导致检索粒度粗、上下文噪声多；太小又丢失完整语义。我们最终用 500 字 + 50 字重叠的切分策略，对表格和代码块单独保留不切分。

## 小结

混合检索不是简单地把两路结果拼在一起，关键在"融合"和"精排"两个环节。BM25 擅长精确匹配，向量擅长语义理解，RRF 让两路结果公平合并，Rerank 再做最后一道精细排序。上线后，知识库问答的首条命中率（用户认为第一条就是答案的比例）从纯向量检索的约 60% 提升到了 80% 以上，尤其是包含错误码、编号、人名的查询改善最为明显。
