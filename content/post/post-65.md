---
title: "智能体工作流编排：从知识库问答到多步任务"
slug: "post-65"
date: 2026-06-02T10:30:00+08:00
draft: false
image: /images/post-65-cover.jpg
tags: ["Agent","工作流","编排"]
categories: ["AI"]
description: "从单轮 RAG 到多步 Agent 工作流，我们在知识库问答服务中的编排实践。"
---

## 单轮 RAG 接不住了

知识库问答服务上线初期只有一条链路：用户提问 → 检索 → 拼 Prompt → 调 LLM → 返回答案。简单可控，但很快被顶到了天花板。

有人问"帮我查一下上个月引用量最高的三篇文献，对比它们的方法，再导出成 Word"。这一句话里藏着检索、排序、对比分析、文档生成四步，单轮 RAG 根本接不住。

我当时的判断是两头都不能走极端：全交给 ReAct 让模型自由发挥，可控性和成本都扛不住；全硬编码成固定 DAG，又失去了灵活性。最后落在一个折中上：工作流骨架 + Agent 节点。

## 一张图，两类节点

我把任务拆成两类节点：

- 确定性节点：检索、SQL 查询、文件解析、导出，这些用代码写死，输入输出明确
- Agent 节点：需要推理、选择、总结的环节，交给 LLM 决定下一步

节点之间用有向图描述，允许条件分支和循环，运行时由一个轻量编排器驱动。每一步的状态写进统一的 `WorkflowState`，节点之间不直接耦合。

![工作流骨架 + Agent 节点的混合编排](/images/post-65-agent-workflow.svg)

核心结构就这么多：

```go
type WorkflowState struct {
    Query     string
    Documents []Document
    Draft     string
    Artifact  string
    Trace     []StepRecord
    mu        sync.Mutex
}

type Node interface {
    Name() string
    Run(ctx context.Context, st *WorkflowState) error
}

type Orchestrator struct {
    nodes   map[string]Node
    edges   map[string][]Edge // from -> edges
}

type Edge struct {
    To    string
    Cond  func(st *WorkflowState) bool // nil 表示无条件
}

func (o *Orchestrator) Run(ctx context.Context, start string, st *WorkflowState) error {
    queue := []string{start}
    visited := map[string]int{}
    for len(queue) > 0 {
        name := queue[0]
        queue = queue[1:]
        if visited[name] >= 5 { // 防止死循环
            return fmt.Errorf("node %s exceeded max retries", name)
        }
        visited[name]++
        if err := o.nodes[name].Run(ctx, st); err != nil {
            return err
        }
        for _, e := range o.edges[name] {
            if e.Cond == nil || e.Cond(st) {
                queue = append(queue, e.To)
            }
        }
    }
    return nil
}
```

Agent 节点内部走 ReAct 循环：模型输出思考 + 工具调用，执行工具后把结果喂回去，直到给出最终答案或触发步数上限。工具调用走 MCP，上一篇讲过。拿"查文献→对比→导出"来说，检索和导出是确定性节点，中间的对比分析交给 Agent 节点。

## 四个坑

第一个坑，state 越攒越肥。一开始我们把所有中间结果都塞进 `WorkflowState`，跑到后面堆满文档全文和历史消息，token 直接爆炸。后来立了规矩：节点只输出下一阶段需要的最小字段，长文本进对象存储，state 里只留 ID 和摘要。

第二个坑，循环没有刹车。LLM 偶尔会陷入"反复检索但不给出答案"的死循环。现在每个节点有最大重试次数，整图有总步数和总 token 预算，超限直接中断，返回当前最优结果，而不是无限烧钱。

第三个坑，没有 trace 就是瞎子。多步工作流出问题，不查 trace 根本说不清哪一步偏了。我们在每个节点进入/退出时写结构化日志（节点名、输入摘要、输出摘要、耗时、token 数），用 trace_id 串起来，在 Jaeger 里能看完整的节点瀑布图。代码里的 `StepRecord` 就是干这个的。

第四个不算坑，算一条划边界的原则：流程稳定、容错要求高的（支付、对账、数据同步）用确定性 DAG，甚至上 Temporal；探索性、开放式的任务（调研、写作、分析）用 Agent 节点。两者可以混在一张图里，但关键路径上的不可恢复操作，别让 Agent 碰。

## 后来

回头看，从单轮 RAG 走到多步工作流，是把"模型一次想清楚"换成了"系统分步兜底"：确定性节点负责可靠，Agent 节点负责灵活，编排器把两者粘起来，顺便守住成本和循环上限。

下一步我们在试把常用工作流做成模板，让业务方自己拖拽配置，不用每次都找后端写代码。

> 封面图：[ell brown / Flickr](https://www.flickr.com/photos/39415781@N06/7522618254) · CC BY 2.0
