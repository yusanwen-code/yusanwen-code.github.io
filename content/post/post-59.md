---
title: "结构化技能包：把 Agent 人格特质封装为可复用模块"
slug: "post-59"
date: 2026-02-28T10:30:00+08:00
draft: false
image: /images/post-59-cover.jpg
tags: ["Agent", "Prompt", "技能包"]
categories: ["AI"]
description: "为什么用一段大 prompt 做人设会失控，以及金丹技能包的结构设计"
---

## 问题背景

在知识库问答服务项目里，我们最初给企业客户定制 Agent，就是改一段 system prompt：开头写"你是一个 XX 助手"，中间堆一堆语气要求，结尾补几条禁忌。结果维护起来非常痛苦：客户 A 要"学术严谨"，客户 B 要"活泼亲切"，两份 prompt 八成内容重复，改一处公共措辞要同步十几份；更糟的是，prompt 写长了之后，模型对后半段指令的遵循度明显下降，"必须用 markdown 表格回答"和"回答控制在三句话"这种约束经常被忽略。

做 alchemy-furnace 时，我决定从根上换个思路：**不把人格写成一段散文，而是拆成结构化字段，每个字段有明确职责，由程序拼装成最终 prompt。** 这就是金丹（Elixir）技能包。

## 方案/设计

一个金丹是一份版本化的结构化文档，核心字段包括：

- `identity`：身份设定，一句话（"你是一位资深 Go 后端工程师"）。
- `expertise`：专长标签数组，用于检索和融合权重（`["Go","分布式","RAG"]`）。
- `tone`：语气维度的结构化打分（`formality: 0.8, conciseness: 0.6, humor: 0.2`），而不是"既专业又亲切"这种模糊描述。
- `principles`：行为原则列表，每条是一句可执行指令（"回答前先判断问题属于哪一层：协议/框架/业务"）。
- `constraints`：硬约束（`max_length`、`forbidden_topics`、`must_use_markdown`）。
- `few_shots`：示例对话数组，结构化存 input/output，而不是埋在正文里。
- `tools`：允许调用的工具白名单（对应 MCP / function calling）。
- `priority` 与 `conflicts_with`：融合时的优先级和冲突声明。
- `version` 与 `content_hash`：版本和内容指纹，用于缓存和血统。

这个结构的关键在于：**它既是给 LLM 看的（可渲染成 prompt），也是给程序看的（可校验、可 diff、可融合）。** 渲染逻辑由引擎统一控制，用户只填字段，不直接写整段 prompt。

## 关键代码

Go 侧的结构体和 GORM 模型（简化版）：

```go
type Elixir struct {
    ID            int64     `gorm:"primaryKey;autoIncrement:false" json:"id"` // snowflake
    Name          string    `gorm:"size:128;not null" json:"name"`
    Version       int       `gorm:"not null;default:1" json:"version"`
    Identity      string    `gorm:"type:text" json:"identity"`
    Expertise     StringSlice `gorm:"type:json" json:"expertise"`
    Tone          ToneSpec  `gorm:"type:json" json:"tone"`
    Principles    StringSlice `gorm:"type:json" json:"principles"`
    Constraints   Constraints `gorm:"type:json" json:"constraints"`
    FewShots      []FewShot `gorm:"type:json" json:"few_shots"`
    Tools         StringSlice `gorm:"type:json" json:"tools"`
    Priority      int       `gorm:"default:100" json:"priority"`
    ConflictsWith StringSlice `gorm:"type:json" json:"conflicts_with"`
    ContentHash   string    `gorm:"size:64" json:"content_hash"`
    CreatedAt     time.Time `json:"created_at"`
}

type ToneSpec struct {
    Formality   float64 `json:"formality"`   // 0~1
    Conciseness float64 `json:"conciseness"`
    Humor       float64 `json:"humor"`
    Empathy     float64 `json:"empathy"`
}
```

渲染成 prompt 的函数放在 Python 引擎侧，因为这块会随模型表现频繁调：

```python
def render_elixir(e: dict) -> str:
    parts = [f"# 身份\n{e['identity']}"]

    if e.get("expertise"):
        parts.append("# 专长\n" + "、".join(e["expertise"]))

    tone = e.get("tone", {})
    tone_line = []
    if tone.get("formality", 0) >= 0.7: tone_line.append("措辞正式严谨")
    if tone.get("conciseness", 0) >= 0.7: tone_line.append("回答简洁，避免铺垫")
    if tone.get("humor", 0) >= 0.5: tone_line.append("可适度幽默")
    if tone_line:
        parts.append("# 语气\n" + "；".join(tone_line))

    if e.get("principles"):
        parts.append("# 行为原则\n" +
            "\n".join(f"- {p}" for p in e["principles"]))

    c = e.get("constraints", {})
    if c:
        cons = []
        if c.get("max_length"): cons.append(f"回答不超过 {c['max_length']} 字")
        if c.get("must_use_markdown"): cons.append("使用 Markdown 排版")
        for t in c.get("forbidden_topics", []):
            cons.append(f"禁止讨论：{t}")
        if cons:
            parts.append("# 硬性约束\n" + "\n".join(f"- {x}" for x in cons))

    if e.get("few_shots"):
        shots = ["# 示例"]
        for i, fs in enumerate(e["few_shots"], 1):
            shots.append(f"## 示例 {i}\n用户：{fs['input']}\n助手：{fs['output']}")
        parts.append("\n".join(shots))

    return "\n\n".join(parts)
```

`content_hash` 在入库时计算，用 `sha256` 对规范化后的 JSON 取摘要，任何字段改动都会让 hash 变化，这是后面缓存失效和血统追溯的基础。

## 踩坑/权衡

**字段过多会吓退用户**。第一版我设计了二十多个字段，结果自己填都嫌烦。后来我把字段分成必填（identity、expertise、principles）和可选（tone、few_shots、tools），前端编辑器用折叠面板，普通用户只看必填三项，高级用户再展开 tone 滑块和 few-shot 编辑器。

**结构化会损失表现力**。有些人格特质确实很难用字段表达，比如"那种老北京茶馆里提笼架鸟的松弛感"。我的折中是保留一个 `style_notes` 自由文本字段，但明确标注它"权重低于结构化字段，仅作补充"，渲染时放在最后。让模型既吃结构化的硬指令，又有一点自由发挥的空间。

**few-shot 存哪里**。示例对话可能很长，全塞 MySQL 的 JSON 字段会让行膨胀。我的做法是短示例直接存库，长附件（比如整段对话日志）存 S3，Elixir 里只留 `few_shot_refs` 引用，渲染前由引擎批量拉取。这跟我在数据治理服务里做 S3 预签名上传是同一套思路。

**版本与克隆**。金丹一旦被某个分身引用就不可原地修改，改动要新建 version，旧分身继续引用旧版本。这避免了"我没改 prompt 怎么 Agent 性格变了"的灵异问题。

## 小结

把人格从一段大 prompt 重构为结构化技能包，本质上是把"提示词工程"拉回"软件工程"：字段是接口，渲染是实现，版本和 hash 是可复现性的保证。它让复用、diff、融合、缓存这些在散文 prompt 上几乎做不了的事变得自然。金丹这一层立住了，多金丹融合才有可靠的输入。

> 封面图：[karen horton / Flickr](https://www.flickr.com/photos/8790226@N06/3494617614) · CC BY 2.0
