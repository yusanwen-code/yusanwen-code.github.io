---
title: "light_rag 轻量检索在知识库问答中的集成"
date: 2025-02-03T10:30:00+08:00
draft: false
tags: ["RAG","light_rag","检索"]
categories: ["AI"]
description: "轻量级 RAG 框架 light_rag 的接入与调优"
---

## 问题背景

知识库问答服务 最早的 RAG 方案是传统的"向量检索 + TopK 拼接"：把用户问题向量化，去 Milvus 里查最相似的 chunk，拼进 prompt 喂给模型。这种方案在单文档、短问答场景够用，但在跨文档、多实体关系的复杂问题上表现很差——比如问"A 公司和 B 公司在 2023 年有哪些合作项目"，向量检索只能找到包含关键词的片段，无法关联跨文档的实体关系。

我们调研了 GraphRAG，效果不错但太重：需要构建完整的知识图谱、社区检测、层级摘要，索引一次要几个小时，资源消耗也大。对于我们很多中小规模知识库（几百到几千篇文档），用 GraphRAG 属于大炮打蚊子。light_rag 正好填补了这个空白。

## 方案设计

light_rag 的核心思想是轻量级图谱增强检索：

1. **实体和关系抽取**：文档入库时，用 LLM 抽取实体和关系，存入图结构（KV 存储即可，不依赖 Neo4j）。
2. **双重检索**：查询时同时做向量检索（低层，找具体片段）和图谱检索（高层，找实体关联），结果去重合并。
3. **增量更新**：新文档只需抽取新的实体和关系，不需要重建整个图谱。

我们在 数据集管理服务 中用 Python（FastAPI）集成 light_rag 做索引构建，在 知识库问答服务（Go）中通过 HTTP 调用检索接口。索引数据存 MongoDB，向量存 Qdrant。

## 关键代码

light_rag 索引构建的 Python 服务：

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

在 知识库问答服务 主流程中根据问题类型选择检索模式：

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

## 踩坑与权衡

- **实体抽取成本**：light_rag 索引时每篇文档都要调 LLM 抽取实体，文档量大时 API 费用不低。我们用 `gpt-4o-mini` 做抽取，成本比 GPT-4o 低一个量级，质量也够用。对于特别大的知识库，建议先做文档过滤，只索引高价值内容。
- **检索模式选择**：`naive` 就是纯向量检索，`local` 侧重实体关联，`global` 侧重社区关系摘要，`hybrid` 是两者结合。实际测试中 `hybrid` 效果最好但延迟也最高（约增加 300-800ms），我们对延迟敏感的场景默认用 `local`，复杂问题才用 `hybrid`。
- **图谱存储**：light_rag 默认用 NetworkX（内存图），重启后从 KV 存储恢复。万级实体以内没问题，十万级以上建议换 Neo4j。我们的知识库规模在万级以内，NetworkX 足够。
- **并发索引**：多篇文档同时 `ainsert` 会有写冲突，light_rag 内部用文件锁。我们在 数据集管理服务 用 pond 池化控制同一知识库的并发索引数，避免锁竞争。
- **和现有 RAG 的关系**：light_rag 没有完全替代原有向量检索，而是作为可选检索器接入。对于不需要图谱的简单知识库，用户可以在配置里选择"纯向量模式"，不引入额外的索引开销。

## 小结

light_rag 在传统向量 RAG 和重型 GraphRAG 之间找到了一个不错的平衡点：图谱增强带来了跨文档关联能力，增量更新和轻量存储又不至于让索引流程变得不可承受。对于我们这种几百到几千篇文档的企业知识库，它的投入产出比是最合适的。检索模式可切换的设计也让我们能根据问题复杂度灵活权衡效果和延迟。
