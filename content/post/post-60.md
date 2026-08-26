---
title: "多金丹融合：Promptbreeder 风格的变异算子与血统追溯"
slug: "post-60"
date: 2026-03-16T10:30:00+08:00
draft: false
tags: ["Promptbreeder", "Agent", "进化算法"]
categories: ["AI"]
description: "用 crossover 和 mutation 算子融合多个人格，并记录完整血统"
---

## 问题背景

单个金丹是一个静态人格，但 alchemy-furnace 真正有意思的地方在于"炼丹"——把多个金丹扔进炉子里，产出一个兼具各方特质的新人格。我最初的实现很朴素：把几个金丹渲染成 prompt 拼在一起，让 LLM "综合一下"。结果非常糟糕：模型倾向于简单拼接，"你既是 A 又是 B 又是 C"，输出人格左右横跳，而且每次结果都不一样，无法复现，也说不清楚新人格到底继承了谁的什么特质。

我需要的是一套**有结构的融合算子**，而不是"请综合一下"。Promptbreeder 那套用进化算法搜索 prompt 的思路给了我启发：把融合看作一代进化，用 crossover 交换特质、用 mutation 产生变异，并且为每个产物记录血统（lineage）。

## 方案/设计

我实现了三类核心算子：

- **Crossover（交叉）**：取两个金丹，按字段维度交换/混合。语气维度（tone）取加权平均；原则（principles）按 priority 去重合并；示例（few_shots）各取若干；硬冲突字段（constraints）交给 LLM 裁决并记录理由。
- **Mutation（变异）**：在一个金丹基础上做小幅度扰动——强化某一维度的语气、替换一条 principle 的措辞、增删一条 constraint。变异幅度可控（`mutation_rate`），用于在已有满意人格附近做探索。
- **Ensemble（集成）**：不合成单一 prompt，而是生成一个"委员会"人格——遇到问题先判断该由哪种专长主导，再调用对应子人格的风格回答。这个算子对"专长差异大"的金丹组合更稳。

每个融合任务的输出不只是一段 system prompt，还包含一份 `lineage`：

```json
{
  "agent_id": "agt_xxx",
  "operator": "crossover",
  "parents": [
    {"elixir_id": 101, "version": 3, "hash": "a1b2..."},
    {"elixir_id": 205, "version": 1, "hash": "c3d4..."}
  ],
  "resolution_notes": [
    {"field": "max_length", "chose": "来自金丹A，因 priority 更高"},
    {"field": "humor", "chose": "加权平均 0.35"}
  ],
  "params": {"temperature": 0.7, "provider": "deepseek", "op_version": "v2"},
  "lineage_hash": "9f8e..."
}
```

`lineage_hash` 是对 parents 的 hash、算子名、参数、算子版本的 sha256，用来唯一标识这次"血统组合"。相同输入相同参数重跑会命中缓存（下一篇讲），并能判断两个分身是否同源。

## 关键代码

Crossover 算子（Python 引擎侧）的核心逻辑：

```python
import random, statistics

def crossover_operator(elixirs: list[dict], rate: float = 0.5) -> str:
    assert len(elixirs) >= 2
    a, b = elixirs[0], elixirs[1]

    # 语气：加权平均（priority 高的权重大）
    wa = a.get("priority", 100)
    wb = b.get("priority", 100)
    total = wa + wb
    tone = {}
    for k in ("formality", "conciseness", "humor", "empathy"):
        va = a.get("tone", {}).get(k, 0.5)
        vb = b.get("tone", {}).get(k, 0.5)
        tone[k] = round((va * wa + vb * wb) / total, 2)

    # 原则：按 priority 排序去重合并
    principles = dedup_merge(
        a.get("principles", []),
        b.get("principles", []),
    )

    # 示例：各取一半
    few_shots = (a.get("few_shots", [])[:2] +
                 b.get("few_shots", [])[:2])

    # 硬冲突：交给 LLM 裁决（这里简化为取 priority 高者）
    constraints, notes = resolve_constraints(a, b)

    child = {
        "identity": synthesize_identity(a, b),  # LLM 生成新身份句
        "expertise": list({*a["expertise"], *b["expertise"]}),
        "tone": tone,
        "principles": principles,
        "constraints": constraints,
        "few_shots": few_shots,
        "tools": list({*a.get("tools", []), *b.get("tools", [])}),
    }
    return render_elixir(child)
```

Mutation 算子，只动一个金丹：

```python
def mutate_operator(elixir: dict, rate: float = 0.3) -> str:
    child = copy.deepcopy(elixir)
    # 随机扰动一个语气维度
    if random.random() < rate and child.get("tone"):
        key = random.choice(list(child["tone"].keys()))
        delta = random.uniform(-0.2, 0.2)
        child["tone"][key] = round(
            min(1.0, max(0.0, child["tone"][key] + delta)), 2)

    # 随机替换一条 principle 的措辞（交给 LLM 改写）
    if random.random() < rate and child.get("principles"):
        idx = random.randrange(len(child["principles"]))
        child["principles"][idx] = llm_rewrite_principle(
            child["principles"][idx])

    child["version"] = child.get("version", 1) + 1
    return render_elixir(child)
```

血统记录在任务完成时统一构建：

```python
def build_lineage(elixirs, operator, params, notes):
    parents = [{"elixir_id": e["id"], "version": e["version"],
                "hash": e["content_hash"]} for e in elixirs]
    payload = {
        "parents": parents, "operator": operator,
        "params": params, "op_version": OP_VERSION,
    }
    lineage_hash = hashlib.sha256(
        json.dumps(payload, sort_keys=True).encode()).hexdigest()
    return {**payload, "resolution_notes": notes,
            "lineage_hash": lineage_hash}
```

## 踩坑/权衡

**交叉不是简单拼接**。第一版我直接把两个金丹的 principles 列表 concat，结果 prompt 里出现自相矛盾的两条原则。后来加上 `dedup_merge`——先用 embedding 相似度去重（我在数据集管理服务里做向量化那套直接复用），再让 LLM 对剩余冲突逐条裁决。去重这一步很关键，它能把两个"意思一样但措辞不同"的原则合并掉。

**变异太大会跑偏**。`mutation_rate` 设到 0.5 以上时，产物几乎认不出祖先。我默认用 0.2~0.3，并且每次变异只动一到两个字段，保证"可辨识的连续性"。这跟遗传算法里探索与利用的权衡是一回事。

**Ensemble 算子的代价**。委员会人格每次回答要先做一次路由判断（"这个问题该谁主导"），多一次 LLM 调用，延迟和成本都更高。我让它只在金丹专长差异度（expertise 的 Jaccard 距离）超过阈值时作为默认算子，否则用 crossover。

**血统要防篡改**。lineage 是用户判断"这个分身靠不靠谱"的依据，所以我把 `lineage_hash` 连同产物一起落库，Go 网关读取时校验 hash，防止有人手动改 parents 冒充血统。

## 小结

多金丹融合的关键不是"让 LLM 综合一下"，而是用结构化算子控制组合过程，用血统记录可解释、可复现。Crossover 做组合，Mutation 做探索，Ensemble 处理专长差异，lineage_hash 做身份账本。这套机制让炼丹从"开盲盒"变成了一个可以迭代、可以追溯的工程过程。下一篇讲怎么基于血统做合成提示词缓存。
