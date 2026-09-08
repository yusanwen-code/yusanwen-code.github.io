---
title: "RAG 评测：如何客观衡量知识库问答的效果"
slug: "post-46"
date: 2025-08-09T10:30:00+08:00
categories: ["AI"]
tags: ["RAG","评测","召回率"]
description: "把 RAG 拆成检索和生成两段，分别打分，别只凭感觉"
draft: false
image: /images/post-46-cover.jpg
---

## "到底准不准"，一开始答不上来

知识库问答服务上线后，业务方问得最多的一句话是："你们这个问答到底准不准？"我们只能拿几个 case 演示一下，说"挺准的"。这个答案撑不住正式验收。更麻烦的是，换了切片策略、换了 embedding 模型、加了 rerank 之后，效果到底是变好还是变坏，光靠人工抽几条根本看不出来。

后来我主导建了一套离线评测，思路不复杂：把 RAG 拆成"检索"和"生成"两段，分开打分。混在一起评，出了问题分不清是没召回，还是 LLM 没把上下文用对。

## 两段，各自怎么打分

检索段评召回：给定一个问题，期望命中哪些 chunk，看实际召回的 top-k 里中了几个。

生成段评答案：给定问题、召回上下文、标准答案，让 LLM 当裁判，从忠实度、相关度、完整度三个维度打分。忠实度（faithfulness）看的是有没有胡说——每句话是否都能在上下文里找到依据。

两个环节都依赖一份标注集。我们从真实用户 query 里抽了 300 条，请领域同事标注：每条 query 对应的标准 chunk 和参考答案。300 条不算多，但覆盖了高频问法、长尾术语、跨文档问题三类，做回归够用了。

![RAG 离线评测：一次跑批，出两组指标](/images/post-46-rag-eval.svg)

## 指标怎么算

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

最后在 CI 里挂了一个回归任务：每次改 Prompt、换 embedding 模型、调切片大小，自动跑一遍这 300 条，指标和基线对比，Recall 或 Faithfulness 掉超过 2 个百分点就卡住合并。

## 四个坑

第一个坑是裁判自己就不稳。同一个回答，GPT-4 这次打 4 分、下次打 5 分，基本看运气。我们的对策：温度设 0，Prompt 里给每个分数档位写明确的描述（比如 faithfulness=5 表示"每句话都能在上下文找到依据"），重跑一致性从 70% 提到 88% 左右。再往下抠就没必要了，评测是用来做相对比较的，不是给绝对值盖章。

第二个坑是位置偏见。裁判会偏心上下文里靠前的证据。评测时把召回的 chunk 随机打乱顺序再喂给裁判，别让检索顺序带偏打分。

第三个坑是标注集会过期。文档库一更新，老问题的 gold chunk 可能就失效了。我们每季度 review 一次，顺手把新出现的 bad case 补进集子，标注集从 300 涨到了 500。别指望一步到位，真实失败案例持续沉淀，集子才活得下去。

第四个是框架取舍。RAGAS、TruLens 这类都看过，RAGAS 概念清晰，但在中文和企业术语上，它的指标和人工判断偏差不小。最后我们只借鉴了它的指标定义，Prompt 自己写，可控性更好。

## 后来

这套评测后来成了改动前的必答题。知识库问答服务几次大的 Prompt 和切片策略调整，都是它拦住了"感觉变好、实际变差"的改动。要说原则就两条：检索和生成分开评，不然定位不了问题；手里得有一份能持续回归的标注集，每次改动才有数字可比。

> 封面图：[kstepanoff / Flickr](https://www.flickr.com/photos/68732633@N04/7520487412) · CC BY 2.0
