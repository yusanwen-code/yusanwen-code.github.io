---
title: "知识图谱构建：从非结构化文档到实体关系抽取"
slug: "post-44"
date: 2025-07-09T10:30:00+08:00
categories: ["AI"]
tags: ["知识图谱","NER","信息抽取"]
draft: false
image: /images/post-44-cover.jpg
description: "数据集管理服务里用 LLM 做实体关系抽取的工程实践"
---

## 问题背景

数据集管理服务处理的学术文档里藏着大量结构化知识：谁提出了什么方法、哪个模型在什么数据集上跑了什么结果、某篇论文引用了哪些前人工作。这些信息散落在 PDF 段落里，传统关键词检索只能命中词面，回答不了"X 方法和 Y 方法有什么关联"这类问题。

我们的目标是把这些非结构化文本抽成 (主体, 关系, 客体) 三元组，落进图数据库，再和 light_rag 的向量检索结合，让知识库问答服务在问答时既能做语义召回，又能沿关系做多跳推理。

## 方案设计

整条流水线分四步：切片 → 实体抽取 → 关系抽取 → 实体对齐。

切片不按固定 token 数硬切，而是按章节和段落边界切，保证一个语义单元不被拆碎。实体和关系抽取用 LLM 做，因为学术领域的术语（模型名、数据集名、指标名）NER 模型很难覆盖全，而且关系类型是开放的，不适合提前写死 schema。

实体对齐是关键难点：同一实体在不同论文里可能有不同写法（"BERT"、"BERT-base"、"Devlin 等人提出的 BERT"），必须做一次规范化，否则图里会出现大量重复节点。

## 关键代码

我们用 eino 编排抽取链路，pond 控制并发。实体抽取的 Prompt 大致是这样：

```go
// Entity 抽取节点
type Entity struct {
    ID         string   `json:"id"`          // 规范化后的 ID
    Name       string   `json:"name"`        // 原名
    Type       string   `json:"type"`        // model/dataset/method/metric/...
    Aliases    []string `json:"aliases"`
}

const entityPromptTpl = `你是学术信息抽取助手。请从下面的文本中抽取实体，输出 JSON 数组。
实体类型限定：model, dataset, method, metric, institution, person。
对每个实体，给出一个稳定的 snake_case id（如 "bert_base"），并列出可能的别名。

文本：
%s

只输出 JSON，不要解释。`
```

LLM 返回后做实体对齐：把 Name 和 Aliases 全部丢进一个 Embedding 模型算向量，和库里已有实体做余弦相似度，超过阈值就合并到已有 ID：

```go
func (s *Aligner) Align(ctx context.Context, candidates []Entity) ([]Entity, error) {
    // 批量算 embedding，减少 LLM/Embedding 调用次数
    texts := make([]string, 0, len(candidates)*2)
    for _, c := range candidates {
        texts = append(texts, c.Name)
        texts = append(texts, c.Aliases...)
    }
    embs, err := s.embedder.Embed(ctx, texts)
    if err != nil { return nil, err }

    aligned := make([]Entity, 0, len(candidates))
    idx := 0
    for _, c := range candidates {
        canonical := c
        // 在已有实体向量索引里找最近邻
        if hit, err := s.store.Search(ctx, embs[idx:idx+1+len(c.Aliases)], 0.92); err == nil && hit != nil {
            canonical.ID = hit.ID
        } else {
            s.store.Upsert(ctx, canonical.ID, embs[idx])
        }
        idx += 1 + len(c.Aliases)
        aligned = append(aligned, canonical)
    }
    return aligned, nil
}
```

关系抽取节点要求 LLM 输出三元组，并且只允许引用上一步已经抽出来的实体 ID，避免凭空捏造：

```go
type Triple struct {
    Subject   string `json:"subject_id"`
    Predicate string `json:"predicate"`   // outperforms / uses / cites / evaluates_on ...
    Object    string `json:"object_id"`
    Evidence  string `json:"evidence"`    // 原文证据句，便于溯源
}
```

整个图我们落到 NebulaGraph（这里用伪代码表示写入）：

```text
INSERT VERTEX entity(name, type) VALUES "bert_base":("BERT-base", "model");
INSERT EDGE cites(evidence) VALUES "bert_base"->"attention_is_all_you_need":("...");
```

## 踩坑与权衡

最头疼的是 LLM 抽取出的三元组有"幻觉"。模型会把原文没说的关系凭语感补上。我们加了一道校验：要求每个 Triple 必须带 Evidence 原文句，后处理时做一次字符串包含检查，如果 Evidence 在原切片里找不到就丢弃。这一刀砍掉了大量噪声。

第二个坑是实体类型不一致。同样是 "BERT"，有的地方被标成 method，有的标成 model。我们后来做了一个轻量的规则层：模型名通常出现在 "we use X"、"X model" 这类上下文中，再结合一个高频实体词典，把类型固化下来。

第三个是成本。全量抽取论文 PDF 调用 LLM 的 token 开销很大。我们用了两档模型：结构化抽取用便宜的快模型，实体消歧这类需要语义判断的才用强模型，整体成本降到了全用强模型的三分之一左右。

最后一个权衡：是否要做共指消解。学术论文里 "it"、"this method"、"the latter" 非常多，消解错了会把关系挂到错误实体上。我们评估后选择只在段落内做简单的启发式消解，跨段不做——错一个不如少一个，图谱质量比密度更重要。

## 小结

从非结构化文档构建知识图谱，工程上比算法更难的是"降噪"和"对齐"。用 LLM 做开放抽取召回高，但必须用 Evidence 校验、实体对齐、类型规则把幻觉压下去。我们最终让图谱和向量检索互补：向量负责找相关段落，图谱负责沿关系扩展，知识库问答服务的多跳问答质量有了肉眼可见的提升。

> 封面图：[Neal. / Flickr](https://www.flickr.com/photos/31878512@N06/3839707719) · CC BY 2.0
