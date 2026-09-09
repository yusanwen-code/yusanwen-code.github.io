---
title: "light_rag 轻量检索在知识库问答中的集成"
slug: "post-34"
date: 2025-02-03T10:30:00+08:00
draft: false
image: /images/post-34-cover.jpg
tags: ["RAG","light_rag","检索"]
categories: ["AI"]
description: "轻量级 RAG 框架 light_rag 的接入与调优"
---

## 跨文档的问题，向量检索接不住

知识库问答服务最早的 RAG 方案很朴素：向量检索加 TopK 拼接。用户问题向量化，去 Milvus 里查最相似的 chunk，拼进 prompt 喂给模型。单文档、短问答的场景，这套够用。

跨文档的问题就不行了。比如问"A 公司和 B 公司在 2023 年有哪些合作项目"，向量检索只能捞回包含关键词的片段，两份文档各说各的，实体关系对不上。

我们调研过 GraphRAG，效果确实不错，但太重：要构建完整的知识图谱、做社区检测、生成层级摘要，索引一次几个小时，资源消耗也大。我们的知识库大多是几百到几千篇文档的规模，用 GraphRAG 属于大炮打蚊子。

light_rag 正好填了这个空。

## GraphRAG 太重，纯向量太轻

它的核心思想是轻量级的图谱增强检索，做三件事：

1. 实体和关系抽取：文档入库时用 LLM 抽取实体和关系，存进图结构，KV 存储就够，不依赖 Neo4j；
2. 双重检索：查询时同时做向量检索（低层，找具体片段）和图谱检索（高层，找实体关联），结果去重合并；
3. 增量更新：新文档只抽取新的实体和关系，不需要重建整个图谱。

落地时拆成两个服务：数据集管理服务用 Python（FastAPI）集成 light_rag 做索引构建，知识库问答服务（Go）通过 HTTP 调检索接口。索引数据存 MongoDB，向量存 Qdrant。

![light_rag 的入库与查询两条链路](/images/post-34-lightrag-flow.svg)

## 索引：入库时抽实体和关系

Python 侧的索引服务，主要活儿是把 light_rag 的存储都指到自己的基础设施上：

```python
from lightrag import LightRAG, QueryParam
from lightrag.llm import openai_complete_if_cache, openai_embed
from lightrag.utils import EmbeddingFunc
import numpy as np

async def llm_model_func(prompt, system_prompt=None, history_messages=[], **kwargs):
    return await openai_complete_if_cache(
        "gpt-4o-mini",
        prompt,
        system_prompt=system_prompt,
        history_messages=history_messages,
        api_key=settings.OPENAI_API_KEY,
        base_url=settings.OPENAI_BASE_URL,
        **kwargs,
    )

async def embedding_func(texts):
    resp = await openai_embed(
        texts,
        model="text-embedding-3-small",
        api_key=settings.OPENAI_API_KEY,
        base_url=settings.OPENAI_BASE_URL,
    )
    return np.array(resp)

def get_rag(workspace: str) -> LightRAG:
    return LightRAG(
        working_dir=f"./rag_data/{workspace}",
        llm_model_func=llm_model_func,
        embedding_func=EmbeddingFunc(
            embedding_dim=1536,
            max_token_size=8192,
            func=embedding_func,
        ),
        kv_storage="MongoKVStorage",
        vector_storage="QdrantVectorDBStorage",
        graph_storage="NetworkXStorage",
    )

@app.post("/index/{kb_id}")
async def index_document(kb_id: str, doc: DocumentRequest):
    rag = get_rag(kb_id)
    await rag.ainsert(doc.content)
    return {"status": "ok", "chunks": doc.chunk_count}
```

知识库问答服务 Go 侧调用检索：

```go
type LightRAGClient struct {
    baseURL string
    client  *http.Client
}

type RetrieveRequest struct {
    Query       string `json:"query"`
    Mode        string `json:"mode"`         // "hybrid", "local", "global", "naive"
    TopK        int    `json:"top_k"`
    KnowledgeID string `json:"knowledge_base_id"`
}

type RetrieveResult struct {
    Context  string   `json:"context"`
    Sources  []Source `json:"sources"`
}

func (c *LightRAGClient) Retrieve(ctx context.Context, req RetrieveRequest) (*RetrieveResult, error) {
    body, _ := json.Marshal(req)
    httpReq, err := http.NewRequestWithContext(ctx, "POST",
        c.baseURL+"/retrieve", bytes.NewReader(body))
    if err != nil {
        return nil, err
    }
    httpReq.Header.Set("Content-Type", "application/json")

    resp, err := c.client.Do(httpReq)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()

    var result RetrieveResult
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return nil, err
    }
    return &result, nil
}
```

在知识库问答服务主流程中根据问题类型选择检索模式：

```go
func (h *Handler) selectRAGMode(query string) string {
    // 简单事实性问题用 local，跨文档关联用 hybrid/global
    if isSimpleFactual(query) {
        return "local"
    }
    if containsMultiEntityQuery(query) {
        return "hybrid"
    }
    return "hybrid"
}

result, err := h.ragClient.Retrieve(ctx, RetrieveRequest{
    Query:       req.Query,
    Mode:        h.selectRAGMode(req.Query),
    TopK:        5,
    KnowledgeID: req.KnowledgeBaseID,
})
```

## 几笔权衡

实体抽取是按文档烧 LLM 的。每篇文档入库都要调一次模型抽实体，库一大，API 费用肉眼可见。我们用 `gpt-4o-mini` 做抽取，比 GPT-4o 低一个量级，质量也够用。特别大的知识库，建议先做文档过滤，只索引高价值内容。

检索模式有讲究。`naive` 就是纯向量检索，`local` 侧重实体关联，`global` 侧重社区关系摘要，`hybrid` 是两者结合。实测 `hybrid` 效果最好，延迟也最高，要多花 300 到 800 毫秒。延迟敏感的场景我们默认 `local`，复杂问题才上 `hybrid`。

图谱存储选型，light_rag 默认用 NetworkX，图在内存里，重启后从 KV 存储恢复。万级实体以内没问题，十万级以上建议换 Neo4j。我们的规模在万级以内，NetworkX 足够，就不多背一个图数据库了。

并发索引会打架。多篇文档同时 `ainsert` 有写冲突，light_rag 内部用文件锁兜底，我们在数据集管理服务用 pond 池控制同一知识库的并发索引数，避免锁竞争。

还有它和现有 RAG 的关系：light_rag 没有替代原有的向量检索，而是作为可选检索器接进来。不需要图谱的简单知识库，配置里选"纯向量模式"，就不引入这笔额外的索引开销。

## 平衡点在哪

light_rag 值得选，是因为它位置选得好：夹在传统向量 RAG 和重型 GraphRAG 中间。图谱增强补上了跨文档关联，增量更新和轻量存储又没让索引流程变得难以承受。几百到几千篇文档的企业知识库，它的投入产出比是合适的。至于效果和延迟怎么平衡，检索模式可以切，留给具体场景自己挑。

> 封面图：[archer10 (Dennis) / Flickr](https://www.flickr.com/photos/22490717@N02/21543878609) · CC BY-SA 2.0
