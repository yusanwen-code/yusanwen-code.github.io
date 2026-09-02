---
title: "对话编排层重构：从 Go 业务编排迁移到 Python LangGraph"
slug: "post-76"
date: 2026-09-02T20:00:00+08:00
draft: false
tags: ["架构", "LangGraph", "Agent"]
categories: ["AI"]
description: "提示词构建、群聊调度、模型调用编排，从 Go 网关整体搬进 Python LangGraph，形成「Go 管数据与 CRUD、Python 管智能编排」的分层架构。这篇复盘为什么迁、边界怎么划、图怎么搭、可恢复执行怎么做到。"
---

## 一条报数指令暴露的问题

炼丹炉（[Alchemy Furnace](https://github.com/yusanwen-code/alchemy-furnace)，我的开源项目）的群聊里，我发过这样一条指令：

```text
@全体成员 全体都有！报数！
```

预期很明确：A、B、C、D 四个道人按顺序报 1、2、3、4。实际跑起来，它被当成了闲聊：有时只让一个人接话，有时人设和记忆指令还能把硬指令覆盖掉——报数报成了自由发挥。

这不是一个偶发 bug，是一类问题的缩影：**当编排逻辑长在业务代码里，"确定性指令"和"开放对话"就没有边界**。群聊调度全部写在 Go 网关里，意图分类、发言人选择、轮次策略和业务逻辑缠在一起，每加一个编排能力都要改 Go、编译、发布，而编排恰恰是整个产品里**变化最快**的部分。

于是我做了这次架构迁移：把提示词构建、群聊调度和模型调用编排，整体从 Go 迁到 Python LangGraph，形成**「Go 负责数据与 CRUD，Python 负责智能编排」**的分层。这篇复盘：为什么迁、边界怎么划、图怎么搭、可恢复执行怎么做到。

## Go 在变成 Agent 框架

迁移前炼丹炉是双后端：Go 网关（Gin）+ Python 引擎（FastAPI）。这个结构本身没问题，问题在于**群聊上线后，Go 里长出了第三种性质的职责**。

一轮群聊对话，Go 实际在做三件事：

- **数据**：会话、消息、道人、金丹、记忆、模型的存储与 CRUD，凭据加密——这是 Go 的本行
- **协议**：对前端的 SSE 流、内部服务调用——稳定的契约面
- **智能编排**：意图分类、发言人选择、提示词拼装、模型调用、轮次与收敛策略——高频变化、需要快速实验

第三类和前两类完全不是一种东西。编排层需要的是图结构、状态机、检查点、可恢复执行、结构化输出校验——这些 LangGraph 生态里全是现成的，Go 里全要手写。**让一个后端语言慢慢长成一个 Agent 框架，才是最贵的路线**。

## 分层：Go 管什么，Python 管什么

迁移后的职责边界：

| 职责 | 归属 |
|---|---|
| 认证、请求校验、凭据加密存储 | Go |
| 会话/消息/道人/金丹/记忆/模型的存储与 CRUD | Go |
| 正式消息落库（只在 `assistant_final` 之后，按 run_id 幂等） | Go |
| 内部事件 → 前端 SSE 的翻译 | Go |
| 单聊/群聊路由 | Python LangGraph |
| 指令分类、确定性路由 | Python |
| Supervisor 计划、发言人调度、收敛 | Python |
| 提示词构建、模型调用、重试 | Python |
| 记忆检索策略与记忆提案 | Python 提案 → Go 校验落库 |

一句话版本：**Go 不再选择发言人、不再分类对话意图、不再拼 prompt、不再管轮次策略**。前端仍然只调 Go、只消费 Go 的 SSE——对前端来说契约没变，变的是 SSE 背后的调度从 Go 挪进了图里。

边界里我最在意的一条是**凭据不进图状态**。API key、解密后的凭据走 LangGraph 的 `context_schema`（RuntimeContext：模型网关、凭据、调试开关、取消旗标），与图状态彻底分离——它们绝不进入图状态、SQLite checkpoint、对外事件和日志。图状态里只有快照：历史、道人、金丹、记忆、模型引用，都是 Go 在发起一轮 run 时传进来的不可变快照。

## 图架构：一张会话图，一张可复用的道人图

整个编排是四层图，顶层一张会话图：

```text
ConversationGraph          ← 一次用户轮的入口
├── hydrate_context
├── route_session
├── SingleChatGraph
│   └── DaoistGraph
└── GroupChatGraph
    ├── classify_directive
    ├── deterministic_router
    ├── supervisor
    ├── dispatch_daoists
    │   └── DaoistGraph × N
    ├── convergence
    └── propose_memory
```

关键设计是 **DaoistGraph 作为可复用子图**：单聊直接调它，群聊每个发言人各自子运行一张。单聊和每个群成员走的是**同一条 prompt 构建 + 模型调用管线**——选定记忆、编译人设与金丹行为、调模型、校验响应、流出事件。这一条保证了"行为可解释"：单聊什么效果，群聊里同一个道人就是什么效果，不存在两套 prompt 逻辑。

群聊图里的路由是有讲究的：`classify_directive` 先分类这一轮用户输入，确定性指令走 `deterministic_router` 直接成计划，开放讨论才走 `supervisor` 让模型出计划——这就是下一节。

## 混合导演：该调模型的调模型，不该调的绝不调

群聊调度我用的是**混合导演**策略，核心就一句：**确定性的事情用代码，创造性的事情用模型**。

**确定性指令永不委托模型**。直接 @某个成员、@全体成员、报数、停止/继续——这些必须在代码里走死路径。报数的实现是：路由器为每个成员构造一个**不可变任务**，里面写死序号；人设、记忆、闲聊风格规则只能影响语气，**不能改数字、不能漏人、不能加戏、不能改顺序**。报数这种事交给模型去"理解"，就是开头那个 bug 的根源。

**开放讨论交给 Supervisor**。这一轮该谁说话、按什么顺序、每人拿到什么任务、发言预算多少、要不要收束——由会话默认模型（**非人设**，不扮演任何道人）产出一份结构化计划。Supervisor 不可见、不写用户可见的文本，只出计划。它失败或产出无效计划时，**确定性回退**到被明确 @ 的成员或主成员——导演的错误不传染整轮。

这样分工还有个实际的好处：明确的群指令**不花 Supervisor 的模型调用**，单聊用被选中道人自己配置的模型。钱花在真正需要智能的地方。

## 可恢复执行：中断在发言人边界，续跑按差集

这是整个迁移里技术含量最高的部分，也是最值得抄的部分。

每个用户轮有全局唯一的 `run_id`，每条终稿回复有唯一 `reply_id`，Go 按这两个 ID 做落库幂等。LangGraph 侧用本地异步 SQLite checkpointer 做检查点。用户点停止、前端断连、进程重启——都要能恢复，而且**恢复时不能重复已完成发言人的发言**。

做法是把恢复粒度设计在**发言人边界**：dispatch 节点按计划逐个发言人在子图里跑，每个发言人之前先 `await asyncio.sleep(0)` 让出事件循环再查取消旗标——取消请求只能落在 await 点，这样中断恰好落在发言人之间的缝隙里，不会截断一条发到一半的回复。

续跑靠**差集裁决**。顶层检查点只携带「计划 + 已完成回复」，恢复重放时：

- 计划已存在 → 不重新规划、不重发 `plan_created` 事件
- 已完成的发言人 → 跳过，只在剩余差集上继续

其中藏着一个容易踩的坑，代码里的路由顺序：

```python
def _route_after_router(state) -> Literal["dispatch", "supervisor", "end"]:
    if state.get("speaking_plan"):
        return "dispatch"      # 续跑重放：计划已在，按差集续，不重规划
    kind = state["directive"]["kind"]
    if kind == "open":
        return "supervisor"    # 首轮开放讨论：默认模型出计划
    return "end"               # 停止/继续：控制指令，不产计划
```

**这个判断顺序不能反**。如果先看 `kind`，开放讨论在续跑重放时会误入 supervisor 再调一次模型；先看计划有无，重放才直接走 dispatch 按差集续跑。可恢复执行的全部难度就在这种毫厘之间——状态里每多带一个通道、路由里每换一个判断顺序，恢复语义就完全不同。

失败语义同样是发言人粒度：单个道人失败只跳过该发言人，不阻塞剩余计划成员；道人图内部对模型错误做最多 2 次机械重试；Supervisor 失败走确定性回退。三层兜底，任何一层的失败都不会把整轮炸掉。

## 迁移不是重写：feature flag + 一条真实的提交序列

迁移策略是**增量推进，但结局只有一种实现**——feature flag `orchestration_engine=legacy|langgraph` 是临时迁移控制，不是长期双引擎产品设置。验证通过后默认 LangGraph，短回滚窗口过后删掉 legacy。

真实提交序列（节选自仓库主干）：

```text
docs: design LangGraph conversation orchestration      ← 321 行设计文档
docs: plan LangGraph orchestration migration           ← 873 行实施计划
build(python): add LangGraph runtime dependencies
feat(orchestration): define state and event contracts  ← 状态/事件契约先行
feat(orchestration): add provider-aware model gateway
feat(orchestration): evolve speaking plan to ordered task items
feat(orchestration): route explicit group directives
feat(orchestration): add reusable Daoist graph
feat(orchestration): add hybrid group director
feat(orchestration): add resumable conversation graph
feat(orchestration): expose internal streaming API
feat(chat): persist orchestration runs idempotently
```

节奏是**契约先行**：状态、事件、模型网关先于任何图节点落地；图是一层一层长出来的（道人图 → 确定性路由 → 混合导演 → 可恢复）。整个编排包最终约 1900 行 Python，14 个文件。

验收有一条硬场景，就是开头那条报数：四个成员各回自己的序号，人设只能加语气，不能改数、不能漏人、不能加戏。这条过不了，迁移就不算完。

## 复盘

- **分层不是按语言划的，是按职责性质划的。** 数据是稳定的，编排是高频变化的。把变化最快的职责放进迭代最快的生态——LangGraph 的图结构、checkpointer、子图、结构化输出校验都是现成的，Go 里全要手写。
- **图的节点边界 = 恢复边界。** LangGraph 的检查点落在节点边界，所以节点怎么切，决定能从哪里恢复。想要发言人粒度的恢复，就得把调度切成发言人粒度的节点。
- **确定性与概率性分离，是 Agent 系统的地基。** 能写成代码的绝不调模型；需要模型的环节（Supervisor）只出可校验的结构化计划，失败可回退。开头那个报数 bug，本质就是没有这层分离。
- **契约先行让两端各自演进。** 11 个类型化事件 + run_id 幂等 + 快照式输入，Go 和 Python 之间只有契约没有纠缠；Go 仍然是数据的事实源，Python 在快照上做编排，记忆用提案-校验的方式回流。

这次重构真正的收益在后面：工具调用、人工审批中断（`permission_required` 事件已在契约里预留）、长任务规划、更复杂的多 Agent 协作——这些以后都是"在图里加节点"，不再需要动 Go。架构分层的意义不是当下的优雅，是**把未来的变化留在了便宜的地方**。
