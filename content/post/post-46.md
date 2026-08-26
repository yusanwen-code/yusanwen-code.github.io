---
title: "RAG 评测：如何客观衡量知识库问答的效果"
slug: "post-46"
date: 2025-08-09T10:30:00+08:00
categories: ["AI"]
tags: ["RAG","评测","召回率"]
description: "把 RAG 拆成检索和生成两段，分别打分，别只凭感觉"
draft: false
---

## 问题背景

知识库问答服务上线后，业务方问得最多的一句话是："你们这个问答到底准不准？"一开始我们只能拿几个 case 演示一下，说"挺准的"，但这显然撑不住正式验收。换了切片策略、换了 embedding 模型、加了 rerank 之后，效果到底是变好还是变坏，光靠人工抽几条根本看不出来。

我当时主导了一套 RAG 离线评测方案。核心思路是把 RAG 拆成"检索"和"生成"两段分别评，因为端到端混在一起评，出了问题你不知道是没召回还是 LLM 没用对。

## 方案设计

检索段评估召回质量：给定一个问题，期望命中哪些 chunk，看实际召回的 top-k 里命中了几个。

生成段评估答案质量：给定问题、召回上下文、标准答案，让 LLM 当裁判，从忠实度（faithfulness，是否基于上下文，不胡说）、相关度、完整度三个维度打分。

两个环节都需要一份标注集。我们从真实用户 query 里抽了 300 条，让领域同事标注：每条 query 对应的标准 chunk 和参考答案。300 条不算多，但覆盖了高频问法、长尾术语、跨文档问题三类，足够做回归。

## 关键代码

检索指标用 Recall@k 和 MRR。Recall@k 衡量前 k 个结果里有没有标准答案，MRR 还考虑第一个正确结果出现的位置：

```go
func RetrievalMetrics(expectIDs []string, rankedIDs []string, k int) (recall float64, mrr float64) {
    gold := make(map[string]struct{}, len(expectIDs))
    for _, id := range expectIDs { gold[id] = struct{}{} }

    hit := 0
    firstHit := -1
    for i, id := range rankedIDs {
        if i >= k { break }
        if _, ok := gold[id]; ok {
            hit++
            if firstHit == -1 { firstHit = i + 1 }
        }
    }
    recall = float64(hit) / float64(len(gold))
    if firstHit > 0 { mrr = 1.0 / float64(firstHit) }
    return
}
```

生成段用 LLM-as-Judge。Prompt 要求裁判输出 JSON，方便程序解析：

```go
const judgeTpl = `你是严格的问答评测员。请根据"参考上下文"判断"模型回答"的质量。

问题：%s
参考上下文：
%s
参考答案：
%s
模型回答：
%s

请从以下三个维度打分（0-5，整数），并给出一句话理由：
- faithfulness：回答是否完全基于参考上下文，有没有编造
- relevance：是否回答了问题
- completeness：是否覆盖了参考答案的要点

只输出 JSON：{"faithfulness":N,"relevance":N,"completeness":N,"reason":"..."}`
```

跑评测时，我们把整个 RAG 链路当作黑盒，但在内部埋点把召回的 chunk IDs 也记录下来，这样一次跑批同时产出检索和生成两组指标：

```go
type EvalResult struct {
    QueryID       string
    RecallAt5     float64
    MRR           float64
    Faithfulness  int
    Relevance     int
    Completeness  int
}

func (e *Evaluator) RunOne(ctx context.Context, caseItem Case) EvalResult {
    // 跑 RAG，同时拿到答案和召回的 chunk IDs
    answer, retrieved, err := e.rag.AnswerWithTrace(ctx, caseItem.Query)
    if err != nil { return EvalResult{} }

    recall, mrr := RetrievalMetrics(caseItem.GoldChunkIDs, retrieved, 5)
    scores := e.judge.Score(ctx, caseItem, answer)

    return EvalResult{
        QueryID: caseItem.ID, RecallAt5: recall, MRR: mrr,
        Faithfulness: scores.Faithfulness, Relevance: scores.Relevance,
        Completeness: scores.Completeness,
    }
}
```

最终在 CI 里加了一个回归任务：每次改 Prompt、换 embedding 模型、调切片大小，都自动跑一遍这 300 条，把指标和基线对比，Recall 或 Faithfulness 掉超过 2 个百分点就卡住合并。

## 踩坑与权衡

第一个坑是 LLM 裁判本身不稳定。同一个回答，GPT-4 打 4 分和 5 分是随机的。我们的做法是让裁判温度设为 0，并在 Prompt 里给每个分数档位加明确描述（比如 faithfulness=5 表示"每句话都能在上下文找到依据"），重跑一致性从 70% 提到 88% 左右。再不稳的就接受——评测是用来做相对比较的，不是给绝对值盖章。

第二个坑是位置偏见。裁判模型会倾向给上下文里靠前的证据更高分。我们在评测时把召回 chunk 随机打乱顺序后再喂给裁判，避免被检索顺序带偏。

第三个是标注集维护。文档库更新后，旧问题的 gold chunk 可能失效。我们每季度做一次标注 review，同时把新出现的 bad case 补进集子里，标注集从 300 涨到了 500。关键是别追求一步到位，持续把真实失败 case 沉淀进来。

第四个权衡：是否引入 RAGAS、TruLens 这类框架。我们试过 RAGAS，概念清晰，但在中文和企业术语上它的指标和人工判断偏差不小。最后我们借鉴了它的指标定义，Prompt 自己写，可控性更好。

## 小结

RAG 评测没什么银弹，但有两条原则要守住：一是检索和生成分开评，否则定位不了问题；二是一定要有一份能持续回归的标注集，让每次改动都有数字可对比。知识库问答服务后来几次大的 Prompt 和切片策略调整，都是靠这套评测拦住了"感觉变好实际变差"的改动。
