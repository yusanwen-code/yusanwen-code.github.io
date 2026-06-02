---
title: "智能体工作流编排：从知识库问答到多步任务"
date: 2026-06-02T10:30:00+08:00
draft: false
tags: ["Agent","工作流","编排"]
categories: ["AI"]
description: "从单轮 RAG 到多步 Agent 工作流，我们在 知识库问答服务 中的编排实践。"
---

## 问题背景

知识库问答服务 上线初期只做单轮知识库问答：用户提问 → 检索 → 拼 Prompt → 调 LLM → 返回答案。这个流程简单可控，但很快就遇到瓶颈。用户问的问题越来越复杂："帮我查一下上个月引用量最高的三篇文献，对比它们的方法，再导出成 Word"——这一句话里包含检索、排序、对比分析、文档生成四步，单轮 RAG 根本接不住。

我当时的判断是：不能什么都交给 ReAct 让模型自由发挥，可控性和成本都扛不住；也不能全部硬编码成固定 DAG，那样就失去了灵活性。最终我们采用"工作流骨架 + Agent 节点"的混合编排。

## 方案与设计

我把任务拆成两类节点：

- **确定性节点**：检索、SQL 查询、文件解析、导出——这些用代码写死，输入输出明确
- **Agent 节点**：需要推理、选择、总结的环节，交给 LLM 决定下一步

节点之间用一个有向图描述，图里允许条件分支和循环。运行时由一个轻量编排器驱动，每步把状态写入一个统一的 `WorkflowState`，节点之间不直接耦合。

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

Agent 节点内部走 ReAct 循环：模型输出思考 + 工具调用，执行工具后把结果喂回去，直到给出最终答案或触发步数上限。工具调用走 MCP，上一篇讲过。对于"查文献→对比→导出"这个例子，检索和导出是确定性节点，对比分析是 Agent 节点。

## 踩坑与权衡

**第一，状态管理要克制。** 一开始我们把所有中间结果都塞进 `WorkflowState`，跑到后面 state 里堆满文档全文和历史消息，token 爆炸。后来规定：节点只输出下一阶段需要的最小字段，长文本用对象存储引用，state 里只留 ID 和摘要。

**第二，循环和分支必须有上限。** LLM 偶尔会陷入"反复检索但不给出答案"的循环，我们给每个节点设置最大重试次数，整图设置总步数和总 token 预算，超限直接中断并返回当前最优结果，而不是无限烧钱。

**第三，可观测性是生命线。** 多步工作流出问题时，没有 trace 根本查不出来是哪一步偏了。我们在每个节点进入/退出时写一条结构化日志（节点名、输入摘要、输出摘要、耗时、token 数），并用 trace_id 串起来，在 Jaeger 里能看到完整的节点瀑布图。`StepRecord` 就是干这个的。

**第四，工作流 vs 纯 Agent 的边界。** 我的原则是：流程稳定、容错要求高的（支付、对账、数据同步）用确定性 DAG，甚至上 Temporal；探索性、开放式任务（调研、写作、分析）用 Agent 节点。两者可以混在一张图里，但不要让 Agent 去做关键路径上的不可恢复操作。

## 小结

从单轮 RAG 走到多步工作流，本质是把"模型一次想清楚"换成"系统分步兜底"。确定性节点负责可靠，Agent 节点负责灵活，编排器负责把两者粘起来并守住成本和循环上限。下一步我们在试把常用工作流模板化，让业务方自己拖拽配置，而不是每次都让后端写代码。
